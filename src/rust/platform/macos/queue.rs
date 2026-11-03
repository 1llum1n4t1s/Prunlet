use super::*;
use std::{
    io::{BufRead, BufReader},
    process::{Child, Command, Stdio},
    sync::{Mutex, mpsc},
    thread,
    time::{Duration, Instant},
};
use uuid::Uuid;
const LIMIT: usize = 1024 * 1024;

// 旧socket namespaceも保護対象として保持するが、新しい受付では作成・走査しない。
#[allow(unexpected_cfgs)]
pub(super) fn reserved_namespace_path() -> Result<PathBuf> {
    #[cfg(all(debug_assertions, prunlet_macos_race_tests))]
    if let Some(root) = std::env::var_os("PRUNLET_MACOS_QUEUE_TEST_ROOT") {
        return path::resolve(Path::new(&root), true, false);
    }
    let mut buffer = vec![0u8; 4096];
    let length = unsafe {
        libc::confstr(
            libc::_CS_DARWIN_USER_TEMP_DIR,
            buffer.as_mut_ptr().cast(),
            buffer.len(),
        )
    };
    if length == 0 || length > buffer.len() {
        bail!("Cannot determine OS user runtime directory");
    }
    path::resolve(
        &PathBuf::from(std::str::from_utf8(&buffer[..length - 1])?)
            .join(format!("prunlet-queue-{}", unsafe { libc::geteuid() })),
        true,
        false,
    )
}
#[allow(unexpected_cfgs)]
fn slot_name(slot: usize) -> Result<String> {
    if slot >= 8 {
        bail!("Invalid Mach queue slot");
    }
    let prefix = format!("com.kagayoi.prunlet.queue.{}", unsafe { libc::geteuid() });
    #[cfg(all(debug_assertions, prunlet_macos_race_tests))]
    if let Some(root) = std::env::var_os("PRUNLET_MACOS_QUEUE_TEST_ROOT") {
        use sha2::{Digest, Sha256};
        let digest = Sha256::digest(root.as_bytes());
        return Ok(format!("{prefix}.test.{}.{slot}", hex::encode(digest)));
    }
    Ok(format!("{prefix}.{slot}"))
}
fn slot(base: &str) -> Result<usize> {
    let value = base.as_bytes().first().copied().context("Missing slot")?;
    if !(b'0'..=b'7').contains(&value) {
        bail!("Invalid queue slot capability");
    }
    Ok((value - b'0') as usize)
}
fn token_parts(job: &str) -> Result<(String, mach::Audit)> {
    let fields: Vec<_> = job.split('.').collect();
    if fields.len() != 5
        || fields[0].len() != 32
        || fields[1].len() != 32
        || fields[2].parse::<u64>().is_err()
    {
        bail!("Invalid queue job capability");
    }
    Uuid::parse_str(fields[0])?;
    Uuid::parse_str(fields[1])?;
    slot(fields[0])?;
    let version: u32 = fields[3].parse()?;
    let pid: u32 = fields[4].parse()?;
    if pid == 0 || pid > i32::MAX as u32 || job.len() > 128 {
        bail!("Invalid queue peer identity");
    }
    Ok((
        format!("{}.{}.{}", fields[0], fields[1], fields[2]),
        mach::Audit {
            uid: unsafe { libc::geteuid() },
            pid,
            version,
        },
    ))
}
fn unavailable(job: &str, message: &str) -> Value {
    json!({"jobId":job,"status":"unavailable","expiresUtc":null,"error":message})
}
fn read_message<R: BufRead>(reader: &mut R) -> Result<Value> {
    let mut bytes = Vec::new();
    reader
        .take(LIMIT as u64 + 1)
        .read_until(b'\n', &mut bytes)?;
    if bytes.is_empty() || bytes.len() > LIMIT || bytes.last() != Some(&b'\n') {
        bail!("Missing or oversized queue initialization message");
    }
    Ok(serde_json::from_slice(&bytes)?)
}
fn write_message<W: Write>(writer: &mut W, value: &Value) -> Result<()> {
    let bytes = serde_json::to_vec(value)?;
    if bytes.len() >= LIMIT {
        bail!("Queue message exceeds 1 MiB");
    }
    writer.write_all(&bytes)?;
    writer.write_all(b"\n")?;
    writer.flush()?;
    Ok(())
}
fn contact(job: &str, action: &str) -> Result<Value> {
    let (_, audit) = token_parts(job)?;
    let Some((value, _)) = mach::contact(
        &slot_name(slot(job)?)?,
        &json!({"jobId":job,"action":action}),
        Some(audit),
    )?
    else {
        return Ok(unavailable(
            job,
            "Queue worker is gone; result unknown, do not resend automatically",
        ));
    };
    if value["jobId"] != job || value["serverPid"] != audit.pid {
        bail!("Queue generation did not match");
    }
    Ok(value)
}
struct State {
    status: &'static str,
    result: Option<Value>,
    expires: Option<(Instant, String)>,
}
#[allow(unexpected_cfgs)]
fn retention() -> Duration {
    #[cfg(all(debug_assertions, prunlet_macos_race_tests))]
    if let Ok(value) = std::env::var("PRUNLET_MACOS_TEST_RETENTION_MS") {
        if let Ok(value) = value.parse::<u64>() {
            return Duration::from_millis(value.max(1));
        }
    }
    Duration::from_secs(3600)
}
impl State {
    fn finish(&mut self, status: &'static str, result: Option<Value>) {
        self.status = status;
        self.result = result;
        let duration = retention();
        self.expires = Some((
            Instant::now() + duration,
            (chrono::Utc::now() + chrono::Duration::from_std(duration).unwrap()).to_rfc3339(),
        ));
    }
    fn value(&mut self, job: &str) -> Value {
        if self
            .expires
            .as_ref()
            .is_some_and(|(deadline, _)| Instant::now() >= *deadline)
        {
            self.result = None;
            return json!({"jobId":job,"serverPid":std::process::id(),"status":"unavailable","expiresUtc":self.expires.as_ref().map(|(_,utc)|utc),"capacityReserved":false,"error":"Queue result retention expired; do not resend automatically"});
        }
        let mut value = json!({"jobId":job,"serverPid":std::process::id(),"status":self.status,"expiresUtc":self.expires.as_ref().map(|(_,utc)|utc),"capacityReserved":true});
        if let Some(result) = &self.result {
            value["result"] = result.clone();
        }
        value
    }
}
#[allow(unexpected_cfgs)]
fn serve(config: &Config, base: &str) -> Result<Value> {
    let audit = mach::own_audit()?;
    let job = format!("{base}.{}.{}", audit.version, audit.pid);
    token_parts(&job)?;
    let stdin = std::io::stdin();
    let mut input = BufReader::new(stdin.lock());
    let request = read_message(&mut input)?;
    let stdout = std::io::stdout();
    let mut output = stdout.lock();
    let Some(listener) = mach::Receive::register(&slot_name(slot(base)?)?)? else {
        write_message(&mut output, &json!({"status":"slot_occupied"}))?;
        return Ok(json!({"status":"stopped"}));
    };
    let paths = request["paths"].as_array().context("paths missing")?;
    if paths.is_empty() || paths.len() > 256 {
        bail!("Queue permits 1..256 paths");
    }
    let reservation = prepare_queue(config, &request)?;
    #[cfg(all(debug_assertions, prunlet_macos_race_tests))]
    super::race_tests::barrier("queue-before-ready", json!({"pid":std::process::id()}))?;
    write_message(
        &mut output,
        &json!({"status":"ready","jobId":job,"serverPid":audit.pid}),
    )?;
    let commit = read_message(&mut input)?;
    if commit["start"] != job {
        bail!("Queue start permit did not match");
    }
    #[cfg(all(debug_assertions, prunlet_macos_race_tests))]
    super::race_tests::barrier("queue-before-accepted", json!({"jobId":job}))?;
    // start許可受領後のACK消失は実行取消ではない。
    let _ = write_message(
        &mut output,
        &json!({"status":"accepted","jobId":job,"serverPid":audit.pid}),
    );
    drop(output);
    drop(input);
    let state = Arc::new(Mutex::new(State {
        status: "pending",
        result: None,
        expires: None,
    }));
    let worker_state = state.clone();
    let config = config.clone();
    let _worker_job = job.clone();
    thread::spawn(move || {
        let operation = (|| -> Result<Value> {
            let mut unique = std::collections::BTreeMap::new();
            for (_, tree) in &reservation.prepared {
                for node in &tree.nodes {
                    if node.id.mode & u32::from(libc::S_IFMT) != u32::from(libc::S_IFLNK) {
                        unique.entry((node.id.dev, node.id.ino)).or_insert(node);
                    }
                }
            }
            loop {
                if worker_state
                    .lock()
                    .map_err(|_| anyhow::anyhow!("Queue state unavailable"))?
                    .status
                    != "pending"
                {
                    return Ok(json!({"cancelled":true}));
                }
                for (_, tree) in &reservation.prepared {
                    verify_tree(tree)?;
                }
                let mut locked: Vec<&Pinned> = Vec::new();
                let mut busy = false;
                for node in unique.values() {
                    match FileExt::try_lock_exclusive(node.file.as_ref()) {
                        Ok(()) => locked.push(node),
                        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                            busy = true;
                            break;
                        }
                        Err(e) => return Err(e.into()),
                    }
                }
                if busy {
                    for node in locked {
                        FileExt::unlock(node.file.as_ref())?;
                    }
                    thread::sleep(Duration::from_millis(100));
                    continue;
                }
                let mut state = worker_state
                    .lock()
                    .map_err(|_| anyhow::anyhow!("Queue state unavailable"))?;
                if state.status != "pending" {
                    return Ok(json!({"cancelled":true}));
                }
                state.status = "running";
                drop(state);
                break;
            }
            drop(unique);
            #[cfg(all(debug_assertions, prunlet_macos_race_tests))]
            super::race_tests::barrier("queue-before-sync", json!({"jobId":_worker_job}))?;
            execute_delete(&config, &request, None, Some(reservation))
        })();
        if let Ok(mut state) = worker_state.lock() {
            if state.status == "cancelled" {
                return;
            }
            match operation {
                Ok(value) => {
                    let failed = crate::result_status::has_operation_errors(&value);
                    state.finish(if failed { "failed" } else { "completed" }, Some(value));
                }
                Err(error) => state.finish("failed", Some(json!({"error":error.to_string()}))),
            }
        }
    });
    loop {
        {
            let mut state = state
                .lock()
                .map_err(|_| anyhow::anyhow!("Queue state unavailable"))?;
            if state
                .expires
                .as_ref()
                .is_some_and(|(deadline, _)| Instant::now() >= *deadline)
            {
                state.result = None;
            }
            if state
                .expires
                .as_ref()
                .is_some_and(|(deadline, _)| Instant::now() > *deadline + Duration::from_secs(30))
            {
                break;
            }
        }
        let Some(mut message) = listener.receive(100)? else {
            continue;
        };
        let Ok(request) = message.request() else {
            continue;
        };
        let action = request["action"].as_str().unwrap_or("");
        let probe = action == "probe" && request.get("jobId").is_none();
        if !probe && request["jobId"] != job {
            let _ = message.reply(&unavailable(
                request["jobId"].as_str().unwrap_or(""),
                "Queue slot belongs to a different generation",
            ));
            continue;
        }
        let mut state = state
            .lock()
            .map_err(|_| anyhow::anyhow!("Queue state unavailable"))?;
        let value = if probe {
            let expired = state
                .expires
                .as_ref()
                .is_some_and(|(deadline, _)| Instant::now() >= *deadline);
            json!({"status":if expired{"unavailable"}else{"occupied"},"capacityReserved":!expired})
        } else if action == "cancel" && state.status == "pending" {
            state.finish("cancelled", None);
            state.value(&job)
        } else if action == "cancel" {
            let mut value = state.value(&job);
            value["error"] = json!("Only pending jobs may be cancelled");
            value
        } else if matches!(action, "status" | "probe") {
            state.value(&job)
        } else {
            continue;
        };
        let release = probe && value["capacityReserved"] == false;
        drop(state);
        let _ = message.reply(&value);
        if release {
            break;
        }
    }
    Ok(json!({"status":"stopped"}))
}
struct PendingChild(Option<Child>);
impl std::ops::Deref for PendingChild {
    type Target = Child;
    fn deref(&self) -> &Child {
        self.0.as_ref().expect("pending child")
    }
}
impl std::ops::DerefMut for PendingChild {
    fn deref_mut(&mut self) -> &mut Child {
        self.0.as_mut().expect("pending child")
    }
}
impl Drop for PendingChild {
    fn drop(&mut self) {
        if let Some(child) = self.0.as_mut() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}
struct PreparedReaper(Option<mpsc::Sender<bool>>);
impl PreparedReaper {
    fn commit(mut self) -> bool {
        self.0
            .take()
            .is_some_and(|sender| sender.send(true).is_ok())
    }
}
impl Drop for PreparedReaper {
    fn drop(&mut self) {
        if let Some(sender) = self.0.take() {
            let _ = sender.send(false);
        }
    }
}
fn prepare_reaper(mut pending: PendingChild) -> Result<PreparedReaper> {
    let (sender, receiver) = mpsc::channel();
    #[cfg(all(debug_assertions, prunlet_macos_race_tests))]
    let child_pid = pending.id();
    // OS threadの確保を開始permitより先に済ませる。
    let task = move || {
        if receiver.recv() == Ok(true) {
            let mut child = pending.0.take().expect("pending child");
            let _ = child.wait();
        }
        // Abort/切断時はPendingChildがkill/waitする。
    };
    #[cfg(all(debug_assertions, prunlet_macos_race_tests))]
    if std::env::var("PRUNLET_MACOS_RACE_POINT").ok().as_deref()
        == Some("queue-reaper-thread-failure")
    {
        super::race_tests::barrier("queue-reaper-thread-failure", json!({"childPid":child_pid}))?;
        // BuilderのOS作成失敗と同じclosure破棄を、資源枯渇を起こさず検証する。
        drop(task);
        bail!("Injected queue reaper thread creation failure; request was not accepted");
    }
    thread::Builder::new()
        .name("queue-child-reaper".into())
        .spawn(task)
        .context("Cannot prepare queue child reaper; request was not accepted")?;
    Ok(PreparedReaper(Some(sender)))
}
fn start(
    config: &Config,
    args: &Value,
    base: &str,
    progress: Option<&Progress>,
) -> Result<Option<Value>> {
    let mut child = PendingChild(Some(
        Command::new(std::env::current_exe()?)
            .arg("--config")
            .arg(&config.path)
            .arg("__delete-queue-worker")
            .arg(base)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?,
    ));
    let mut input = child.stdin.take().context("Missing worker stdin")?;
    let output = child.stdout.take().context("Missing worker stdout")?;
    #[cfg(all(debug_assertions, prunlet_macos_race_tests))]
    super::race_tests::barrier("queue-before-request-write", json!({"childPid":child.id()}))?;
    write_message(&mut input, args)?;
    let (tx, rx) = mpsc::channel();
    thread::Builder::new()
        .name("queue-initialization-reader".into())
        .spawn(move || {
            let mut reader = BufReader::new(output);
            loop {
                let message = read_message(&mut reader);
                let failed = message.is_err();
                if tx.send(message).is_err() || failed {
                    break;
                }
            }
        })
        .context("Cannot prepare queue initialization reader; request was not accepted")?;
    let deadline = Instant::now() + Duration::from_secs(15);
    let ready = loop {
        match rx.recv_timeout(Duration::from_secs(1)) {
            Ok(Ok(value)) => break value,
            Err(mpsc::RecvTimeoutError::Timeout) if Instant::now() < deadline => {
                if let Some(p) = progress {
                    p(
                        json!({"message":"Waiting for queue preflight and initialization acknowledgement"}),
                    );
                }
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                bail!("Queue worker did not acknowledge initialization; request was not accepted");
            }
        }
    };
    if ready["status"] == "slot_occupied" {
        drop(input);
        return Ok(None);
    }
    if ready["status"] != "ready" {
        let _ = child.kill();
        let _ = child.wait();
        bail!("Queue initialization was refused: {ready}");
    }
    let job = ready["jobId"]
        .as_str()
        .context("Missing ready capability")?
        .to_owned();
    let (prefix, audit) = token_parts(&job)?;
    if prefix != base || audit.pid != child.id() {
        let _ = child.kill();
        let _ = child.wait();
        bail!("Worker initialization acknowledgement did not match");
    }
    let reaper = prepare_reaper(child)?;
    write_message(&mut input, &json!({"start":job}))?;
    drop(input);
    // permit送信後はACKが失われても実行中の子をkillしない。
    if !reaper.commit() {
        return Ok(Some(unavailable(
            &job,
            "Queue reaper acknowledgement was lost after start; inspect status and do not resend",
        )));
    }
    let accepted = rx.recv_timeout(Duration::from_secs(5));
    match accepted {
        Ok(Ok(value)) if value["status"] == "accepted" && value["jobId"] == job => Ok(Some(
            json!({"jobId":job,"status":"pending","expiresUtc":null}),
        )),
        _ => Ok(Some(unavailable(
            &job,
            "Queue start acknowledgement was lost; inspect status and do not resend",
        ))),
    }
}
pub(super) fn execute(
    config: &Config,
    command: &str,
    args: &Value,
    progress: Option<Progress>,
) -> Result<Value> {
    if command == "__delete-queue-worker" {
        return serve(
            config,
            args["jobId"]
                .as_str()
                .context("Missing worker capability")?,
        );
    }
    if matches!(
        command,
        "delete-queue-status" | "delete-queue-cancel" | "__delete-queue-contact"
    ) {
        let job = args["jobId"].as_str().context("jobId required")?;
        token_parts(job)?;
        let action = if command == "delete-queue-cancel" {
            "cancel"
        } else if command == "__delete-queue-contact" {
            args["action"].as_str().context("Missing contact action")?
        } else {
            "status"
        };
        return Ok(contact(job, action).unwrap_or_else(|e| unavailable(job, &e.to_string())));
    }
    if command != "delete-queue" {
        bail!("Unsupported macOS queue command");
    }
    if serde_json::to_vec(args)?.len() >= LIMIT {
        bail!("Queue input exceeds 1 MiB");
    }
    for index in 0..8 {
        let available = match mach::contact(&slot_name(index)?, &json!({"action":"probe"}), None) {
            Ok(None) => true,
            Ok(Some((value, _))) => {
                value["status"] == "unavailable" && value["capacityReserved"] == false
            }
            Err(_) => false,
        };
        if !available {
            continue;
        }
        let mut id = Uuid::new_v4().simple().to_string();
        id.replace_range(0..1, &index.to_string());
        let base = format!(
            "{id}.{}.{}",
            Uuid::new_v4().simple(),
            chrono::Utc::now().timestamp_millis()
        );
        if let Some(value) = start(config, args, &base, progress.as_ref())? {
            #[cfg(all(debug_assertions, prunlet_macos_race_tests))]
            let value = {
                let mut observed = value;
                observed["admissionProbes"] = json!(index + 1);
                observed
            };
            return Ok(value);
        }
    }
    bail!("Shared user queue limit (8) reached or a fixed slot is unavailable")
}
