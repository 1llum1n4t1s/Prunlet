use super::bounded_input::{BoundedInput, Line};
use anyhow::{Context, Result, anyhow, bail};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::{self, BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, mpsc};
use std::thread;
use std::time::{Duration, Instant};

pub struct Generation {
    pub executable: PathBuf,
    pub identity: String,
    pub lease: Box<dyn Send>,
}
pub type Resolver = Arc<dyn Fn() -> Result<Generation> + Send + Sync>;

#[derive(Debug)]
pub struct RetryLater(pub String);
impl std::fmt::Display for RetryLater {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}
impl std::error::Error for RetryLater {}

enum Event {
    Input(io::Result<Option<Line>>),
    Output(u64, String),
    Closed(u64, String),
    Written(u64, WriteKind, io::Result<()>),
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum WriteKind {
    Regular,
    Internal,
}
struct Outbound {
    raw: String,
    kind: WriteKind,
}
enum BackendEvent {
    Output(bool),
    Written(WriteKind),
}
struct InternalCompletion {
    written: bool,
    responded: bool,
}
impl InternalCompletion {
    fn accept(&mut self, event: BackendEvent) -> Result<()> {
        match event {
            BackendEvent::Written(WriteKind::Internal) if !self.written => self.written = true,
            BackendEvent::Output(true) if !self.responded => self.responded = true,
            BackendEvent::Output(false) => {}
            _ => bail!("Unexpected MCP backend event during internal initialization"),
        }
        Ok(())
    }
    fn complete(&self) -> bool {
        self.written && self.responded
    }
}

fn spawn_writer(
    mut input: impl Write + Send + 'static,
    serial: u64,
    events: mpsc::Sender<Event>,
) -> mpsc::Sender<Outbound> {
    let (sender, requests) = mpsc::channel::<Outbound>();
    thread::spawn(move || {
        // 受付側は完了通知まで次の要求を受けないため、queueは最大1要求。
        // sender切断時も受付済み要求を書き切ってからstdinを閉じる。
        for request in requests {
            let result = input
                .write_all(request.raw.as_bytes())
                .and_then(|()| input.write_all(b"\n"))
                .and_then(|()| input.flush());
            let failed = result.is_err();
            let _ = events.send(Event::Written(serial, request.kind, result));
            if failed {
                break;
            }
        }
    });
    sender
}
struct Pending {
    id: Value,
    initialize: Option<Value>,
    _lease: Box<dyn Send>,
}
struct Backend {
    process: Child,
    input: Option<mpsc::Sender<Outbound>>,
    identity: String,
    serial: u64,
}
struct Proxy {
    events: mpsc::Receiver<Event>,
    sender: mpsc::Sender<Event>,
    backend: Option<Backend>,
    pending: HashMap<String, Pending>,
    initialize: Option<Value>,
    ready: bool,
    serial: u64,
    failed: bool,
    notification_lease: Option<Box<dyn Send>>,
}

fn emit(value: &Value) -> Result<()> {
    let mut output = io::stdout().lock();
    serde_json::to_writer(&mut output, value)?;
    output.write_all(b"\n")?;
    output.flush()?;
    Ok(())
}
fn rpc_error(id: Value, code: i32, message: impl Into<String>) -> Result<()> {
    emit(&json!({"jsonrpc":"2.0","id":id,"error":{"code":code,"message":message.into()}}))
}
fn key(id: &Value) -> Result<String> {
    if !id.is_string() && !id.is_number() {
        bail!("Request id must be a string or number.");
    }
    Ok(id.to_string())
}

fn release_after_completion<T>(
    pending: &mut HashMap<String, Pending>,
    wait: impl FnOnce() -> io::Result<T>,
) -> io::Result<T> {
    let result = wait()?;
    pending.clear();
    Ok(result)
}
fn parse_input(line: &Line) -> Result<Value, (Value, i32, String)> {
    let invalid = |message: &str| (Value::Null, -32600, message.to_owned());
    if line.exceeds_limit {
        return Err(invalid("Request exceeds 1 MiB."));
    }
    let value: Value =
        serde_json::from_str(&line.text).map_err(|e| (Value::Null, -32700, e.to_string()))?;
    if !value.is_object() {
        return Err(invalid("Expected a JSON-RPC object."));
    }
    if let Some(id) = value.get("id") {
        key(id).map_err(|e| invalid(&e.to_string()))?;
    }
    let id = value.get("id").cloned().unwrap_or(Value::Null);
    if value["jsonrpc"] != "2.0"
        || !(value.get("method").is_some_and(Value::is_string)
            || (value.get("id").is_some()
                && (value.get("result").is_some() ^ value.get("error").is_some())))
    {
        return Err((id, -32600, "Invalid JSON-RPC request.".into()));
    }
    Ok(value)
}

impl Proxy {
    fn resolve(&mut self, resolver: &Resolver) -> Result<Generation> {
        let start = Instant::now();
        let mut reported = start;
        loop {
            match resolver() {
                Ok(generation) => return Ok(generation),
                Err(error) if error.downcast_ref::<RetryLater>().is_some() => {
                    if start.elapsed() >= Duration::from_secs(600) {
                        return Err(error.context(
                            "Timed out waiting for MCP backend update; request was not sent",
                        ));
                    }
                    if reported.elapsed() >= Duration::from_secs(30) {
                        eprintln!("Waiting for MCP backend update: {error}");
                        reported = Instant::now();
                    }
                    match self.events.recv_timeout(Duration::from_millis(250)) {
                        Ok(Event::Output(serial, raw))
                            if self.backend.as_ref().is_some_and(|b| b.serial == serial) =>
                        {
                            if let Err(error) = self.output(&raw, None) {
                                self.failed = true;
                                return Err(error);
                            }
                        }
                        Ok(Event::Closed(serial, reason))
                            if self.backend.as_ref().is_some_and(|b| b.serial == serial) =>
                        {
                            self.failed = true;
                            bail!("{reason}");
                        }
                        Ok(Event::Input(_)) => {
                            bail!("Unexpected client input during MCP update wait")
                        }
                        Err(mpsc::RecvTimeoutError::Disconnected) => {
                            bail!("MCP proxy event channel closed")
                        }
                        _ => {}
                    }
                }
                Err(error) => return Err(error),
            }
        }
    }
    fn send(&mut self, raw: &str, kind: WriteKind) -> Result<()> {
        let input = self
            .backend
            .as_mut()
            .and_then(|b| b.input.as_mut())
            .context("MCP backend is not connected")?;
        input
            .send(Outbound {
                raw: raw.to_owned(),
                kind,
            })
            .map_err(|_| anyhow!("MCP backend stdin writer disconnected"))?;
        Ok(())
    }
    fn start(&mut self, config: &Path, generation: &Generation) -> Result<()> {
        let mut command = Command::new(&generation.executable);
        #[cfg(windows)]
        crate::update::mcp_backend::configure_child(&mut command, &generation.identity)?;
        command
            .arg("--config")
            .arg(config)
            .arg("mcp")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x08000000); // CREATE_NO_WINDOW
        }
        let mut process = command.spawn().context("Cannot start MCP backend")?;
        let input = process.stdin.take().context("Missing MCP backend stdin")?;
        let output = process
            .stdout
            .take()
            .context("Missing MCP backend stdout")?;
        self.serial += 1;
        let serial = self.serial;
        self.backend = Some(Backend {
            process,
            input: Some(spawn_writer(input, serial, self.sender.clone())),
            identity: generation.identity.clone(),
            serial,
        });
        let sender = self.sender.clone();
        thread::spawn(move || {
            // 応答は要求より大きくなり得るため、要求の1 MiB制限を流用しない。
            let mut reader = BufReader::new(output);
            loop {
                let mut line = String::new();
                match reader.read_line(&mut line) {
                    Ok(0) => {
                        let _ =
                            sender.send(Event::Closed(serial, "MCP backend stdout closed".into()));
                        break;
                    }
                    Ok(_) => {
                        if sender.send(Event::Output(serial, line)).is_err() {
                            break;
                        }
                    }
                    Err(error) => {
                        let _ = sender.send(Event::Closed(
                            serial,
                            format!("MCP backend stdout failed: {error}"),
                        ));
                        // UTF-8不正等でJSON読取を停止してもpipeを排出し、
                        // 子の正常終了待ちがstdoutの背圧で止まることを防ぐ。
                        let _ = io::copy(&mut reader, &mut io::sink());
                        break;
                    }
                }
            }
        });
        Ok(())
    }
    fn output(&mut self, raw: &str, internal: Option<&str>) -> Result<bool> {
        let mut value: Value = serde_json::from_str(raw).context("Invalid MCP backend JSON")?;
        if !value.is_object() || value["jsonrpc"] != "2.0" {
            bail!("Invalid MCP backend JSON-RPC response");
        }
        if let Some(method) = value.get("method") {
            if !method.is_string() {
                bail!("Invalid MCP backend method");
            }
            if let Some(id) = value.get("id") {
                key(id)?;
                // 現製品はserver要求を発行しない。世代切替中の応答待ちを
                // 暗黙に導入せず、未対応の双方向要求では安全に停止する。
                bail!("MCP backend server requests are not supported by this proxy");
            }
            emit(&value)?;
            return Ok(false);
        }
        let id = value.get("id").context("Missing MCP backend response id")?;
        let id_key = key(id)?;
        if !(value.get("result").is_some() ^ value.get("error").is_some()) {
            bail!("Invalid MCP backend response");
        }
        if internal == Some(id_key.as_str()) {
            if value.get("error").is_some() {
                bail!("Replacement MCP backend refused initialize");
            }
            return Ok(true);
        }
        let pending = self
            .pending
            .get(&id_key)
            .context("Unknown MCP backend response id")?;
        if pending.initialize.is_some() && value.get("result").is_some() {
            if let Some(tools) = value
                .pointer_mut("/result/capabilities/tools")
                .and_then(Value::as_object_mut)
            {
                tools.insert("listChanged".into(), Value::Bool(true));
            }
        }
        // client stdoutが切断された場合も、unknown終了処理までleaseを保持する。
        emit(&value)?;
        if value.get("result").is_some() {
            if let Some(params) = pending.initialize.as_ref() {
                self.initialize = Some(params.clone());
            }
        }
        self.pending.remove(&id_key);
        Ok(false)
    }
    fn receive_output(&mut self, internal: Option<&str>) -> Result<BackendEvent> {
        loop {
            match self
                .events
                .recv()
                .context("MCP proxy event channel closed")?
            {
                Event::Output(serial, raw)
                    if self.backend.as_ref().is_some_and(|b| b.serial == serial) =>
                {
                    return self.output(&raw, internal).map(BackendEvent::Output);
                }
                Event::Written(serial, kind, result)
                    if self.backend.as_ref().is_some_and(|b| b.serial == serial) =>
                {
                    result.context("MCP backend stdin write failed; request outcome is unknown")?;
                    return Ok(BackendEvent::Written(kind));
                }
                Event::Closed(serial, reason)
                    if self.backend.as_ref().is_some_and(|b| b.serial == serial) =>
                {
                    bail!("{reason}")
                }
                Event::Input(_) => bail!("Unexpected client input during MCP handover"),
                _ => {}
            }
        }
    }
    fn drain(&mut self) -> Result<()> {
        while !self.pending.is_empty() {
            self.receive_output(None)?;
        }
        Ok(())
    }
    fn send_internal(&mut self, raw: &str, response: Option<&str>) -> Result<()> {
        self.send(raw, WriteKind::Internal)?;
        let mut completion = InternalCompletion {
            written: false,
            responded: response.is_none(),
        };
        while !completion.complete() {
            completion.accept(self.receive_output(response)?)?;
        }
        Ok(())
    }
    fn stop(&mut self) -> Result<()> {
        if let Some(backend) = self.backend.as_mut() {
            // EOFでqueue workerを含む既存の正常終了経路へ入る。killしない。
            drop(backend.input.take());
            let serial = backend.serial;
            loop {
                match self
                    .events
                    .recv()
                    .context("MCP proxy event channel closed")?
                {
                    Event::Output(found, raw) if found == serial => {
                        self.output(&raw, None)?;
                    }
                    Event::Closed(found, reason) if found == serial => {
                        if reason != "MCP backend stdout closed" {
                            bail!("{reason}");
                        }
                        break;
                    }
                    Event::Input(_) => bail!("Unexpected client input during MCP shutdown"),
                    _ => {}
                }
            }
            let status = self
                .backend
                .as_mut()
                .expect("connected backend")
                .process
                .wait()?;
            self.backend.take();
            if !status.success() {
                bail!("MCP backend exited unsuccessfully");
            }
        }
        Ok(())
    }
    fn select(&mut self, config: &Path, generation: &Generation) -> Result<()> {
        if self
            .backend
            .as_ref()
            .is_some_and(|b| b.identity == generation.identity)
        {
            return Ok(());
        }
        self.drain()?;
        self.stop()?;
        self.start(config, generation)?;
        if let Some(params) = self.initialize.clone() {
            let id = Value::String(format!("prunlet-proxy-initialize-{}", self.serial));
            let id_key = key(&id)?;
            self.send_internal(
                &json!({"jsonrpc":"2.0","id":id,"method":"initialize","params":params}).to_string(),
                Some(&id_key),
            )?;
            if self.ready {
                self.send_internal(
                    r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                    None,
                )?;
                emit(&json!({"jsonrpc":"2.0","method":"notifications/tools/list_changed"}))?;
            }
        }
        Ok(())
    }
    fn unknown(&mut self) {
        for pending in self.pending.values() {
            let _ = rpc_error(
                pending.id.clone(),
                -32603,
                "MCP backend disconnected or returned an invalid response. The operation outcome is unknown; do not automatically retry. Check the original target and the OS bin.",
            );
        }
        // wrapper終了時のjob closeより先に、子の実処理終了を確認する。
        // unknown通知後もleaseを保持し、送信済み要求は再送しない。
        if let Some(backend) = self.backend.as_mut() {
            drop(backend.input.take());
            loop {
                match release_after_completion(&mut self.pending, || backend.process.wait()) {
                    Ok(_) => break,
                    Err(error) => {
                        eprintln!(
                            "Cannot confirm MCP backend exit; keeping operation leases and waiting: {error}"
                        );
                        thread::sleep(Duration::from_secs(1));
                    }
                }
            }
            self.backend.take();
        } else {
            self.pending.clear();
        }
        self.notification_lease.take();
    }
}

pub fn run(config: &Path, resolver: Resolver) -> Result<()> {
    let (sender, events) = mpsc::channel();
    let (permit, permits) = mpsc::sync_channel::<()>(1);
    let input_sender = sender.clone();
    thread::spawn(move || {
        let mut input = BoundedInput::new(io::stdin());
        while permits.recv().is_ok() {
            let line = input.read_stdin_line();
            let end = !matches!(&line, Ok(Some(_)));
            if input_sender.send(Event::Input(line)).is_err() || end {
                break;
            }
        }
    });
    let mut proxy = Proxy {
        events,
        sender,
        backend: None,
        pending: HashMap::new(),
        initialize: None,
        ready: false,
        serial: 0,
        failed: false,
        notification_lease: None,
    };
    permit.send(())?;
    let result = (|| -> Result<()> {
        loop {
            match proxy
                .events
                .recv()
                .context("MCP proxy event channel closed")?
            {
                Event::Input(Ok(Some(line))) => {
                    if line.whitespace {
                        permit.send(())?;
                        continue;
                    }
                    let value = match parse_input(&line) {
                        Ok(value) => value,
                        Err((id, code, message)) => {
                            rpc_error(id, code, message)?;
                            permit.send(())?;
                            continue;
                        }
                    };
                    let id = value.get("id").cloned();
                    let method = value.get("method").and_then(Value::as_str);
                    if method.is_none() {
                        rpc_error(
                            id.unwrap_or(Value::Null),
                            -32600,
                            "No server request is pending.",
                        )?;
                        permit.send(())?;
                        continue;
                    }
                    if id
                        .as_ref()
                        .is_some_and(|id| proxy.pending.contains_key(&id.to_string()))
                    {
                        // 同じIDへ拒否と元要求の成功を両方返すと、実行有無を誤認する。
                        // 元要求だけを結果不明にして接続を停止し、二件目は送信しない。
                        bail!("Duplicate pending MCP request id; duplicate request was not sent");
                    }
                    let generation = match proxy.resolve(&resolver) {
                        Ok(generation) => generation,
                        Err(error) => {
                            if let Some(id) = id {
                                rpc_error(
                                    id,
                                    -32603,
                                    format!(
                                        "MCP backend unavailable; request was not sent: {error}"
                                    ),
                                )?;
                            } else {
                                eprintln!("MCP notification was not sent: {error}");
                            }
                            if proxy.failed {
                                return Err(error);
                            }
                            permit.send(())?;
                            continue;
                        }
                    };
                    if let Err(error) = proxy.select(config, &generation) {
                        if let Some(id) = id {
                            rpc_error(
                                id,
                                -32603,
                                format!(
                                    "MCP backend handover failed; request was not sent: {error}"
                                ),
                            )?;
                        }
                        return Err(error);
                    }
                    if let Some(id) = id {
                        proxy.pending.insert(
                            key(&id)?,
                            Pending {
                                id,
                                initialize: (method == Some("initialize"))
                                    .then(|| value.get("params").cloned().unwrap_or(Value::Null)),
                                _lease: generation.lease,
                            },
                        );
                    } else {
                        proxy.notification_lease = Some(generation.lease);
                    }
                    proxy.send(&line.text, WriteKind::Regular)?;
                    if method == Some("notifications/initialized") && proxy.initialize.is_some() {
                        proxy.ready = true;
                    }
                }
                Event::Input(Ok(None)) => {
                    proxy.drain()?;
                    return proxy.stop();
                }
                Event::Input(Err(error)) => return Err(error.into()),
                Event::Output(serial, raw)
                    if proxy.backend.as_ref().is_some_and(|b| b.serial == serial) =>
                {
                    proxy.output(&raw, None)?;
                }
                Event::Written(serial, WriteKind::Regular, result)
                    if proxy.backend.as_ref().is_some_and(|b| b.serial == serial) =>
                {
                    result.context("MCP backend stdin write failed; request outcome is unknown")?;
                    proxy.notification_lease.take();
                    permit.send(())?;
                }
                Event::Written(serial, WriteKind::Internal, _)
                    if proxy.backend.as_ref().is_some_and(|b| b.serial == serial) =>
                {
                    bail!("Unexpected internal MCP stdin completion");
                }
                Event::Closed(serial, reason)
                    if proxy.backend.as_ref().is_some_and(|b| b.serial == serial) =>
                {
                    return Err(anyhow!(reason));
                }
                _ => {}
            }
        }
    })();
    if result.is_err() {
        proxy.unknown();
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    fn line(text: &str) -> Line {
        Line {
            text: text.into(),
            exceeds_limit: false,
            whitespace: false,
        }
    }
    #[test]
    fn blocked_stdin_writer_does_not_block_output_events_and_closes_after_flush() {
        struct BlockedWriter {
            entered: mpsc::Sender<()>,
            release: Option<mpsc::Receiver<()>>,
            dropped: mpsc::Sender<()>,
            bytes: Arc<std::sync::Mutex<Vec<u8>>>,
        }
        impl Write for BlockedWriter {
            fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
                if let Some(release) = self.release.take() {
                    self.entered.send(()).unwrap();
                    release.recv().unwrap();
                }
                self.bytes.lock().unwrap().extend_from_slice(bytes);
                Ok(bytes.len())
            }
            fn flush(&mut self) -> io::Result<()> {
                Ok(())
            }
        }
        impl Drop for BlockedWriter {
            fn drop(&mut self) {
                let _ = self.dropped.send(());
            }
        }
        let (events, receiver) = mpsc::channel();
        let (entered, entered_rx) = mpsc::channel();
        let (release, release_rx) = mpsc::channel();
        let (dropped, dropped_rx) = mpsc::channel();
        let bytes = Arc::new(std::sync::Mutex::new(Vec::new()));
        let writer = spawn_writer(
            BlockedWriter {
                entered,
                release: Some(release_rx),
                dropped,
                bytes: bytes.clone(),
            },
            9,
            events.clone(),
        );
        writer
            .send(Outbound {
                raw: "request".into(),
                kind: WriteKind::Regular,
            })
            .unwrap();
        entered_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        events.send(Event::Output(9, "progress".into())).unwrap();
        assert!(matches!(
            receiver.recv_timeout(Duration::from_secs(5)).unwrap(),
            Event::Output(9, _)
        ));
        drop(writer);
        assert!(dropped_rx.try_recv().is_err());
        release.send(()).unwrap();
        assert!(matches!(
            receiver.recv_timeout(Duration::from_secs(5)).unwrap(),
            Event::Written(9, WriteKind::Regular, Ok(()))
        ));
        dropped_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(&*bytes.lock().unwrap(), b"request\n");
    }
    #[test]
    fn internal_initialize_waits_for_write_and_response_in_either_order() {
        for response_first in [false, true] {
            let mut completion = InternalCompletion {
                written: false,
                responded: false,
            };
            let mut events = vec![
                BackendEvent::Written(WriteKind::Internal),
                BackendEvent::Output(true),
            ];
            if response_first {
                events.reverse();
            }
            completion.accept(events.remove(0)).unwrap();
            assert!(!completion.complete());
            completion.accept(BackendEvent::Output(false)).unwrap();
            assert!(!completion.complete());
            completion.accept(events.remove(0)).unwrap();
            assert!(completion.complete());
        }
    }
    #[test]
    fn input_accepts_future_methods_and_client_responses() {
        assert!(
            parse_input(&line(
                r#"{"jsonrpc":"2.0","id":"new","method":"future/method","params":{"x":1}}"#
            ))
            .is_ok()
        );
        assert!(parse_input(&line(r#"{"jsonrpc":"2.0","id":7,"result":{}}"#)).is_ok());
        assert_ne!(key(&json!(7)).unwrap(), key(&json!("7")).unwrap());
    }
    #[test]
    fn input_rejects_invalid_envelopes_without_dispatch() {
        for text in [
            "[]",
            "{",
            r#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#,
            r#"{"jsonrpc":"2.0","id":1,"result":{},"error":{}}"#,
        ] {
            assert!(parse_input(&line(text)).is_err());
        }
        let mut oversized = line("{}");
        oversized.exceeds_limit = true;
        assert_eq!(parse_input(&oversized).unwrap_err().1, -32600);
    }

    #[test]
    fn invalid_backend_frames_keep_pending_leases_until_safe_shutdown() {
        use std::sync::atomic::{AtomicBool, Ordering};
        struct Lease(Arc<AtomicBool>);
        impl Drop for Lease {
            fn drop(&mut self) {
                self.0.store(true, Ordering::SeqCst);
            }
        }
        let released = Arc::new(AtomicBool::new(false));
        let (sender, events) = mpsc::channel();
        let mut proxy = Proxy {
            events,
            sender,
            backend: None,
            pending: HashMap::new(),
            initialize: None,
            ready: false,
            serial: 0,
            failed: false,
            notification_lease: None,
        };
        proxy.pending.insert(
            "1".into(),
            Pending {
                id: json!(1),
                initialize: None,
                _lease: Box::new(Lease(released.clone())),
            },
        );
        for raw in [
            "not json",
            r#"{"jsonrpc":"2.0","id":2,"result":{}}"#,
            r#"{"jsonrpc":"2.0","id":1,"result":{},"error":{}}"#,
            r#"{"jsonrpc":"2.0","id":3,"method":"future/serverRequest"}"#,
        ] {
            assert!(proxy.output(raw, None).is_err());
            assert!(proxy.pending.contains_key("1"));
            assert!(!released.load(Ordering::SeqCst));
        }
        drop(proxy);
        assert!(released.load(Ordering::SeqCst));
    }

    #[test]
    fn unknown_shutdown_keeps_leases_until_child_exit_is_confirmed() {
        use std::sync::atomic::{AtomicBool, Ordering};
        struct Lease(Arc<AtomicBool>);
        impl Drop for Lease {
            fn drop(&mut self) {
                self.0.store(true, Ordering::SeqCst);
            }
        }
        let released = Arc::new(AtomicBool::new(false));
        let mut pending = HashMap::new();
        pending.insert(
            "1".into(),
            Pending {
                id: json!(1),
                initialize: None,
                _lease: Box::new(Lease(released.clone())),
            },
        );
        let failed_wait = release_after_completion(&mut pending, || {
            assert!(!released.load(Ordering::SeqCst));
            Err::<(), _>(io::Error::other("exit is not confirmed"))
        });
        assert!(failed_wait.is_err());
        assert!(!released.load(Ordering::SeqCst));
        assert_eq!(pending.len(), 1);
        release_after_completion(&mut pending, || {
            assert!(!released.load(Ordering::SeqCst));
            Ok(())
        })
        .unwrap();
        assert!(released.load(Ordering::SeqCst));
        assert!(pending.is_empty());
    }
}
