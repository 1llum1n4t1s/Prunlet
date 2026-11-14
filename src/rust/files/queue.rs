//! キューの実体snapshotと結果はworkerのメモリーにだけ保持する。
use super::recordless::{self, Snapshot};
use crate::{
    config::Config,
    json::parse_unique,
    platform::windows::{self as native, OwnedHandle, security},
};
use anyhow::{Context, Result, bail};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    io::Write,
    os::windows::io::AsRawHandle,
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use windows_sys::Win32::{
    Foundation::*,
    Security::{Authorization::*, *},
    Storage::FileSystem::*,
    System::{Pipes::*, Threading::*},
};
const MAX_FRAME: usize = 1024 * 1024;
// 受理入力の上限と、保持した最終結果の照会上限を分離する。
// 入力は256path/1MiB、各診断はWindowsの最大path長で有界であり128MiBへ収まる。
const MAX_RESPONSE_FRAME: usize = 128 * 1024 * 1024;
#[cfg(test)]
type MissingPipeHook = Box<dyn FnOnce() -> Result<()> + Send>;
#[cfg(test)]
static CONTACT_MISSING_HOOK: Mutex<Option<(String, MissingPipeHook)>> = Mutex::new(None);
fn validate_id(id: &str) -> Result<()> {
    if id.len() != 32
        || !id
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
    {
        bail!("Queue job ID must contain 32 lowercase hexadecimal characters");
    }
    Ok(())
}
fn pipe_name(id: &str) -> Result<Vec<u16>> {
    validate_id(id)?;
    native::wide(std::ffi::OsStr::new(&format!(
        "\\\\.\\pipe\\Prunlet.DeleteQueue.v1.{id}"
    )))
}
fn initial(id: &str) -> Value {
    json!({"jobId":id,"status":"pending","result":null,"error":null,"waitReason":null,"workerProcessId":std::process::id(),"maxWaitSeconds":null,"retentionSeconds":3600,"expiresUtc":null})
}
fn expiry(state: &mut Value) {
    state["expiresUtc"] =
        json!((chrono::Utc::now() + chrono::Duration::seconds(3600)).to_rfc3339());
}
fn terminal(state: &Value) -> bool {
    !matches!(state["status"].as_str(), Some("pending" | "running"))
}
fn write_frame(mut stream: impl Write, value: &Value) -> Result<()> {
    // 長さ接頭辞付きのframe全体を`encode_frame`で作り、一度に書く（送信バイト列は同一）。
    stream.write_all(&encode_frame(value, MAX_FRAME)?)?;
    stream.flush()?;
    Ok(())
}
/// `LocalAlloc`系APIが返した領域をdropで`LocalFree`する。
struct Local(*mut std::ffi::c_void);
impl Drop for Local {
    fn drop(&mut self) {
        unsafe {
            LocalFree(self.0);
        }
    }
}
fn read_frame(stream: &mut std::fs::File, deadline: Instant) -> Result<Value> {
    let mut header = [0u8; 4];
    native::process::read_exact_pipe(stream, &mut header, deadline)?;
    let size = u32::from_le_bytes(header) as usize;
    if size == 0 || size > MAX_FRAME {
        bail!("Invalid queue frame length");
    }
    let mut bytes = vec![0; size];
    native::process::read_exact_pipe(stream, &mut bytes, deadline)?;
    parse_unique(&bytes)
}
pub fn enqueue(config: &Config, args: &Value) -> Result<Value> {
    // Commandの子はprocess primary tokenで起動する。制限付き実効tokenを広げない。
    unsafe {
        let mut thread_token = std::ptr::null_mut();
        if OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, 1, &mut thread_token) != 0 {
            let _token = OwnedHandle::from_raw(thread_token)?;
            bail!(
                "Deferred deletion cannot be enqueued while the caller thread is impersonating. Use a process running under the intended token; deletion was not started."
            );
        }
        let error = GetLastError();
        if error != ERROR_NO_TOKEN {
            return Err(std::io::Error::from_raw_os_error(error as i32).into());
        }
    }
    recordless::normalize_paths(config, args)?;
    let id = uuid::Uuid::new_v4().simple().to_string();
    let request = json!({"jobId":id,"paths":args["paths"],"recursive":args["recursive"].as_bool().unwrap_or(false)});
    let executable = std::env::current_exe()?;
    let frame = encode_frame(&request, MAX_FRAME)?;
    let started = Instant::now();
    let mut child = native::process::spawn_worker(
        &executable,
        &[
            "--config".into(),
            config
                .path
                .to_str()
                .ok_or_else(|| anyhow::anyhow!("Config path must be valid Unicode"))?
                .into(),
            "__delete-queue-worker".into(),
        ],
    )?;
    let input = child
        .input
        .take()
        .ok_or_else(|| anyhow::anyhow!("Missing worker input"))?;
    native::process::write_pipe_deadline(input,frame,Duration::from_secs(30)).with_context(||format!("Queue acceptance could not be confirmed for job {id}; inspect status and source and do not resend deletion"))?;
    let response =
        read_frame(&mut child.output, started + Duration::from_secs(30)).with_context(|| {
            format!("Queue acceptance is unknown for job {id}; do not resend deletion")
        })?;
    if response["jobId"] != id
        || response["status"] != "pending"
        || response["workerProcessId"].as_u64() != Some(child.id as u64)
    {
        bail!(
            "Invalid or failed queue acceptance for job {id}: {}. Inspect status; do not resend deletion",
            response["error"]
        );
    }
    Ok(response)
}
fn new_pipe(id: &str, first: bool) -> Result<OwnedHandle> {
    let sid = security::current_user_sid()?;
    new_pipe_with_security(id, first, &format!("O:{sid}D:P(A;;GA;;;{sid})(A;;GA;;;SY)"))
}
fn new_pipe_with_security(id: &str, first: bool, sddl: &str) -> Result<OwnedHandle> {
    unsafe {
        let text = native::wide(std::ffi::OsStr::new(sddl))?;
        let mut descriptor = std::ptr::null_mut();
        if ConvertStringSecurityDescriptorToSecurityDescriptorW(
            text.as_ptr(),
            1,
            &mut descriptor,
            std::ptr::null_mut(),
        ) == 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        let _descriptor = Local(descriptor);
        let attributes = SECURITY_ATTRIBUTES {
            nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: descriptor,
            bInheritHandle: 0,
        };
        let name = pipe_name(id)?;
        OwnedHandle::from_raw(CreateNamedPipeW(
            name.as_ptr(),
            PIPE_ACCESS_DUPLEX
                | if first {
                    FILE_FLAG_FIRST_PIPE_INSTANCE
                } else {
                    0
                },
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_NOWAIT | PIPE_REJECT_REMOTE_CLIENTS,
            1,
            65536,
            65536,
            5000,
            &attributes,
        ))
    }
}
struct Peer {
    pid: u32,
    _identity: Option<security::EffectiveIdentity>,
}
fn peer_user(pipe: HANDLE, server: bool, expected: &str) -> Result<Peer> {
    unsafe {
        let mut pid = 0;
        let ok = if server {
            GetNamedPipeClientProcessId(pipe, &mut pid)
        } else {
            GetNamedPipeServerProcessId(pipe, &mut pid)
        };
        if ok == 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        let mut effective = None;
        if server {
            let mut prior = std::ptr::null_mut();
            let prior = if OpenThreadToken(
                GetCurrentThread(),
                TOKEN_IMPERSONATE | TOKEN_QUERY,
                1,
                &mut prior,
            ) != 0
            {
                Some(OwnedHandle::from_raw(prior)?)
            } else {
                let error = GetLastError();
                if error != ERROR_NO_TOKEN {
                    return Err(std::io::Error::from_raw_os_error(error as i32).into());
                }
                None
            };
            if ImpersonateNamedPipeClient(pipe) == 0 {
                return Err(std::io::Error::last_os_error().into());
            }
            let identity = security::effective_identity();
            if SetThreadToken(
                std::ptr::null(),
                prior
                    .as_ref()
                    .map_or(std::ptr::null_mut(), |token| token.raw()),
            ) == 0
            {
                std::process::abort();
            }
            let identity = identity?;
            if identity.sid != expected {
                bail!("Queue client effective token belongs to another user");
            }
            effective = Some(identity);
        } else {
            let mut owner = std::ptr::null_mut();
            let mut descriptor = std::ptr::null_mut();
            let code = GetSecurityInfo(
                pipe,
                SE_KERNEL_OBJECT,
                OWNER_SECURITY_INFORMATION,
                &mut owner,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                &mut descriptor,
            );
            if code != 0 {
                return Err(std::io::Error::from_raw_os_error(code as i32).into());
            }
            let _descriptor = Local(descriptor);
            let mut text = std::ptr::null_mut();
            if ConvertSidToStringSidW(owner, &mut text) == 0 {
                return Err(std::io::Error::last_os_error().into());
            }
            let _text = Local(text.cast());
            let mut count = 0;
            while *text.add(count) != 0 {
                count += 1;
            }
            if String::from_utf16(std::slice::from_raw_parts(text, count))? != expected {
                bail!("Queue server object belongs to another user");
            }
        }
        Ok(Peer {
            pid,
            _identity: effective,
        })
    }
}
fn pipe_read_exact(pipe: HANDLE, bytes: &mut [u8], deadline: Instant) -> Result<()> {
    let mut offset = 0;
    while offset < bytes.len() {
        let mut count = 0;
        let ok = unsafe {
            ReadFile(
                pipe,
                bytes[offset..].as_mut_ptr(),
                (bytes.len() - offset) as u32,
                &mut count,
                std::ptr::null_mut(),
            )
        };
        if ok != 0 && count != 0 {
            offset += count as usize;
            continue;
        }
        let error = std::io::Error::last_os_error();
        if ok == 0 && !matches!(error.raw_os_error(), Some(232 | 536)) {
            return Err(error.into());
        }
        if Instant::now() >= deadline {
            bail!("Queue pipe read timed out");
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    Ok(())
}
fn pipe_read_frame(pipe: HANDLE, maximum: usize) -> Result<Value> {
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut header = [0; 4];
    pipe_read_exact(pipe, &mut header, deadline)?;
    let n = u32::from_le_bytes(header) as usize;
    if n == 0 || n > maximum {
        bail!("Invalid queue frame length");
    }
    let mut bytes = vec![0; n];
    let response_deadline = if maximum > MAX_FRAME {
        Instant::now() + Duration::from_secs(5 + (n as u64 / (1024 * 1024)))
    } else {
        deadline
    };
    pipe_read_exact(pipe, &mut bytes, response_deadline)?;
    parse_unique(&bytes)
}
fn encode_frame(value: &Value, max_bytes: usize) -> Result<Vec<u8>> {
    let mut frame = vec![0; 4];
    serde_json::to_writer(&mut frame, value)?;
    let length = frame.len() - 4;
    if length == 0 || length > max_bytes || length > u32::MAX as usize {
        bail!("Queue frame exceeds the limit");
    }
    frame[..4].copy_from_slice(&(length as u32).to_le_bytes());
    Ok(frame)
}
fn pipe_write_frame(pipe: HANDLE, value: &Value) -> Result<()> {
    let bytes = encode_frame(value, MAX_RESPONSE_FRAME)?;
    let mut offset = 0;
    let deadline = Instant::now() + Duration::from_secs(5 + (bytes.len() as u64 / (1024 * 1024)));
    while offset < bytes.len() {
        let mut count = 0;
        let ok = unsafe {
            // NOWAITのbyte pipeへ1frame全体を渡すと、bufferより大きい書込が進まない。
            let count_to_write = (bytes.len() - offset).min(16 * 1024);
            WriteFile(
                pipe,
                bytes[offset..].as_ptr(),
                count_to_write as u32,
                &mut count,
                std::ptr::null_mut(),
            )
        };
        if ok != 0 && count > 0 {
            offset += count as usize;
            continue;
        }
        let error = std::io::Error::last_os_error();
        if ok == 0 && !matches!(error.raw_os_error(), Some(232 | 536)) {
            return Err(error.into());
        }
        if Instant::now() >= deadline {
            bail!("Queue pipe write timed out");
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    Ok(())
}
// DisconnectNamedPipeは未読の応答を破棄する。読み取り完了を待ち、無応答の相手は同じ5秒で打ち切る。
fn flush_response(pipe: HANDLE) -> Result<()> {
    let raw = pipe as usize;
    native::process::cancellable_io("queue-response-flush", Duration::from_secs(5), move || {
        if unsafe { FlushFileBuffers(raw as HANDLE) } == 0 {
            Err(std::io::Error::last_os_error())
        } else {
            Ok(())
        }
    })
}
fn flush_queue_response(pipe: HANDLE, state: &Mutex<Value>) -> Result<()> {
    if let Err(error) = flush_response(pipe) {
        // 接続相手の切断/読取遅延はjobの取消要求ではない。実行基盤の故障だけ停止する。
        if error
            .downcast_ref::<native::process::IoHelperInfrastructureFailure>()
            .is_some()
        {
            stop_pending_on_server_failure(state, &error);
        }
        return Err(error);
    }
    Ok(())
}
pub fn contact(args: &Value, cancel: bool) -> Result<Value> {
    let id = args
        .get("jobId")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow::anyhow!("jobId is required"))?;
    validate_id(id)?;
    let action = (|| -> Result<Value> {
        let name = pipe_name(id)?;
        let deadline = Instant::now() + Duration::from_secs(5);
        let pipe = loop {
            let raw = unsafe {
                CreateFileW(
                    name.as_ptr(),
                    GENERIC_READ | GENERIC_WRITE,
                    0,
                    std::ptr::null(),
                    OPEN_EXISTING,
                    SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION,
                    std::ptr::null_mut(),
                )
            };
            if raw != INVALID_HANDLE_VALUE {
                break unsafe { OwnedHandle::from_raw(raw)? };
            }
            let error = std::io::Error::last_os_error();
            if !matches!(error.raw_os_error(), Some(2 | 231)) || Instant::now() >= deadline {
                return Err(error.into());
            }
            if error.raw_os_error() == Some(2) {
                #[cfg(test)]
                {
                    let hook = {
                        let mut hook = CONTACT_MISSING_HOOK.lock().unwrap();
                        if hook.as_ref().is_some_and(|(expected, _)| expected == id) {
                            hook.take().map(|(_, callback)| callback)
                        } else {
                            None
                        }
                    };
                    if let Some(hook) = hook {
                        hook()?;
                    }
                }
                // 応答後のpipe作り直しの隙間だけを待つ。接続・送信後の要求は再送しない。
                std::thread::sleep(Duration::from_millis(20));
            } else {
                unsafe {
                    WaitNamedPipeW(name.as_ptr(), 100);
                }
            }
        };
        let mut mode = PIPE_READMODE_BYTE | PIPE_NOWAIT;
        if unsafe {
            SetNamedPipeHandleState(pipe.raw(), &mut mode, std::ptr::null(), std::ptr::null())
        } == 0
        {
            return Err(std::io::Error::last_os_error().into());
        }
        let server = peer_user(pipe.raw(), false, &security::current_user_sid()?)?;
        pipe_write_frame(pipe.raw(), &json!(if cancel { "cancel" } else { "status" }))?;
        let result = pipe_read_frame(pipe.raw(), MAX_RESPONSE_FRAME)?;
        if result["jobId"] != id || result["workerProcessId"].as_u64() != Some(server.pid as u64) {
            bail!("Queue response identity differs");
        }
        Ok(result)
    })();
    Ok(match action {
        Ok(result) => result,
        Err(error) => {
            let mut state = initial(id);
            state["workerProcessId"] = json!(0);
            state["status"] = json!("unavailable");
            state["error"] = json!(format!(
                "Worker is inaccessible, stopped, or its result expired. Deletion outcome is unknown; inspect source and Windows Recycle Bin and do not resend deletion. {error:#}"
            ));
            state
        }
    })
}
pub fn worker(config: &Config) -> Result<Value> {
    let mut input = native::process::duplicate_file(std::io::stdin().as_raw_handle())?;
    let request = read_frame(&mut input, Instant::now() + Duration::from_secs(30))?;
    let id = request["jobId"]
        .as_str()
        .ok_or_else(|| anyhow::anyhow!("Missing queue job ID"))?
        .to_owned();
    validate_id(&id)?;
    let mut initial = initial(&id);
    let owner = security::current_user_sid()?;
    let key = hex::encode_upper(Sha256::digest(owner.as_bytes()));
    let mut slot = None;
    for index in 0..8 {
        if let Ok(guard) =
            native::acquire_named_mutex(&format!("Local\\Prunlet.DeleteQueue.v1.{key}.{index}"), 0)
        {
            slot = Some(guard);
            break;
        }
    }
    let Some(_slot) = slot else {
        initial["status"] = json!("failed");
        initial["error"] = json!("The delete queue supports a maximum 8 workers per user");
        write_frame(std::io::stdout().lock(), &initial)?;
        return Ok(Value::Null);
    };
    let accepted = (|| -> Result<_> {
        let paths = recordless::normalize_paths(config, &request)?;
        recordless::validate_queued_paths(config, &paths)?;
        let mut snapshots = vec![];
        let mut count = 0;
        for path in &paths {
            let snapshot =
                Snapshot::capture(path, request["recursive"].as_bool().unwrap_or(false))?;
            count += snapshot.entry_count();
            if count > 4096 {
                bail!("Queue snapshot exceeds the total limit of 4096 entries including parents");
            }
            snapshots.push(snapshot);
        }
        let pipe = new_pipe(&id, true)?;
        let token = native::EffectiveToken::capture()?;
        Ok((paths, snapshots, pipe, token))
    })();
    let (paths, snapshots, first, token) = match accepted {
        Ok(value) => value,
        Err(error) => {
            initial["status"] = json!("failed");
            initial["error"] = json!(format!("{error:#}"));
            write_frame(std::io::stdout().lock(), &initial)?;
            return Ok(Value::Null);
        }
    };
    let state = Arc::new(Mutex::new(initial));
    let snapshots = Mutex::new(snapshots);
    std::thread::scope(|scope| -> Result<()> {
        let execution_state = state.clone();
        let paths = &paths;
        let snapshots = &snapshots;
        let recursive = request["recursive"].as_bool().unwrap_or(false);
        let permit = start_execution(scope, &state, move || {
            if let Err(error) = token.run(|| {
                run_execution(config, paths, snapshots, recursive, &execution_state);
                Ok(())
            }) {
                stop_pending_on_server_failure(&execution_state, &error);
            }
        });
        // 実行threadはACKが成功するまで削除を始めない。起動不能ならfailedを同じpipeで保持する。
        write_frame(std::io::stdout().lock(), &state.lock().unwrap())?;
        if let Some(permit) = permit {
            if permit.send(()).is_err() {
                stop_pending_on_server_failure(
                    &state,
                    &anyhow::anyhow!(
                        "Queue execution worker stopped before initial ACK was acknowledged"
                    ),
                );
            }
        }
        let mut pipe = first;
        loop {
            let expired = {
                let state = state.lock().unwrap();
                terminal(&state)
                    && state["expiresUtc"]
                        .as_str()
                        .and_then(|v| chrono::DateTime::parse_from_rfc3339(v).ok())
                        .is_some_and(|v| v < chrono::Utc::now())
            };
            if expired {
                break;
            }
            let connected = unsafe { ConnectNamedPipe(pipe.raw(), std::ptr::null_mut()) };
            let error = unsafe { GetLastError() };
            if connected == 0 && error == ERROR_PIPE_CONNECTED {
                let _handled = (|| -> Result<()> {
                    let command = pipe_read_frame(pipe.raw(), MAX_FRAME)?;
                    peer_user(pipe.raw(), true, &owner)?;
                    let response = {
                        let mut state = state.lock().unwrap();
                        let mut error = None;
                        if command == "cancel" {
                            if state["status"] == "pending" {
                                state["status"] = json!("cancelled");
                                state["error"] = Value::Null;
                                state["waitReason"] = Value::Null;
                                expiry(&mut state);
                            } else {
                                error = Some(
                                    "Cancellation refused: deletion has started or job is already terminal. Do not resend deletion.",
                                );
                            }
                        } else if command != "status" {
                            error = Some("Unknown queue command.");
                        }
                        let mut copy = state.clone();
                        if let Some(error) = error {
                            copy["error"] = json!(error);
                        }
                        copy
                    };
                    pipe_write_frame(pipe.raw(), &response)?;
                    flush_queue_response(pipe.raw(), &state)?;
                    Ok(())
                })();
                unsafe {
                    DisconnectNamedPipe(pipe.raw());
                }
                drop(pipe);
                pipe = match new_pipe(&id, false) {
                    Ok(pipe) => pipe,
                    Err(error) => {
                        stop_pending_on_server_failure(&state, &error);
                        return Err(error);
                    }
                };
            } else if connected != 0 || error == ERROR_PIPE_LISTENING {
                std::thread::sleep(Duration::from_millis(50));
            } else if error == ERROR_NO_DATA {
                unsafe {
                    DisconnectNamedPipe(pipe.raw());
                }
            } else {
                let error: anyhow::Error = std::io::Error::from_raw_os_error(error as i32).into();
                stop_pending_on_server_failure(&state, &error);
                return Err(error);
            }
        }
        Ok(())
    })?;
    Ok(Value::Null)
}

fn start_execution<'scope, 'env, F>(
    scope: &'scope std::thread::Scope<'scope, 'env>,
    state: &Mutex<Value>,
    run: F,
) -> Option<std::sync::mpsc::Sender<()>>
where
    F: FnOnce() + Send + 'scope,
{
    let (sender, receiver) = std::sync::mpsc::channel();
    match native::process::spawn_scoped(scope, "queue-execution-worker", move || {
        // 初回ACK失敗時はsender破棄で終了し、削除を始めない。
        if receiver.recv().is_ok() {
            run();
        }
    }) {
        Ok(_) => Some(sender),
        Err(error) => {
            stop_pending_on_server_failure(
                state,
                &anyhow::anyhow!(
                    "Queue execution worker could not be started; no deletion was attempted: {error}"
                ),
            );
            None
        }
    }
}
fn run_execution(
    config: &Config,
    paths: &[PathBuf],
    snapshots: &Mutex<Vec<Snapshot>>,
    recursive: bool,
    state: &Mutex<Value>,
) {
    let mut started = false;
    let action = (|| -> Result<_> {
        loop {
            if state.lock().unwrap()["status"] != "pending" {
                return Ok(None);
            }
            let probe = (|| -> Result<()> {
                let held = snapshots.lock().unwrap();
                for snapshot in held.iter() {
                    snapshot.verify()?;
                }
                for snapshot in held.iter() {
                    snapshot.probe()?;
                }
                Ok(())
            })();
            match probe {
                Ok(()) => {}
                Err(error)
                    if error.chain().any(|e| {
                        e.downcast_ref::<std::io::Error>()
                            .is_some_and(|e| matches!(e.raw_os_error(), Some(32 | 33)))
                    }) =>
                {
                    state.lock().unwrap()["waitReason"] = json!(format!(
                        "Waiting for a Windows sharing or lock violation to clear: {error:#}"
                    ));
                    std::thread::sleep(Duration::from_secs(1));
                    continue;
                }
                Err(error) => return Err(error),
            }
            {
                let mut state = state.lock().unwrap();
                if state["status"] != "pending" {
                    return Ok(None);
                }
                for snapshot in snapshots.lock().unwrap().iter() {
                    snapshot.verify()?;
                }
                state["status"] = json!("running");
                state["waitReason"] = Value::Null;
                started = true;
            }
            // Coreの失敗はWindowsへの投入有無を区別したまま受け取り、下の写像で状態を決める。
            return Ok(Some(recordless::delete_checked(
                config,
                paths,
                false,
                recursive,
                None,
                Some(snapshots),
            )));
        }
    })();
    let mut state = state.lock().unwrap();
    if !terminal(&state) {
        match action {
            Ok(Some(Err(failure))) => {
                let (status, error) = core_failure_state(&failure);
                state["status"] = json!(status);
                state["error"] = json!(error);
            }
            Ok(Some(Ok(result))) => {
                let status = if result.items.iter().any(|x| x.status == "ambiguous") {
                    "ambiguous"
                } else if result.items.iter().any(|x| x.status == "failed") {
                    "failed"
                } else {
                    "completed"
                };
                state["result"] = serde_json::to_value(result).unwrap_or(Value::Null);
                state["status"] = json!(status);
                if status != "completed" {
                    state["error"] = json!(
                        "Deletion did not fully succeed. Inspect item results and Windows Recycle Bin; do not resend deletion."
                    );
                }
            }
            Ok(None) => {}
            Err(error) => {
                state["status"] = json!(if started { "ambiguous" } else { "failed" });
                state["error"] = json!(format!(
                    "{} {error:#}",
                    if started {
                        "Deletion started; outcome is unknown. Do not resend deletion."
                    } else {
                        "Deletion was not started."
                    }
                ));
            }
        }
        state["waitReason"] = Value::Null;
        expiry(&mut state);
    }
    snapshots.lock().unwrap().clear();
}
/// `running`へ移った後にCore全体が失敗したときのジョブ状態。
///
/// Coreが投入前で止まったと確定した場合だけ`failed`とし、元対象が保持された原因を残す。
/// それ以外（投入後・投入有無不明）は`ambiguous`のまま再送禁止を明示する。
fn core_failure_state(failure: &recordless::DeleteFailure) -> (&'static str, String) {
    if failure.is_not_submitted() {
        (
            "failed",
            format!(
                "Deletion was not started; no item was submitted to Windows. {:#}",
                failure.error()
            ),
        )
    } else {
        (
            "ambiguous",
            format!(
                "Deletion started; outcome is unknown. Do not resend deletion. {:#}",
                failure.error()
            ),
        )
    }
}
fn stop_pending_on_server_failure(state: &Mutex<Value>, error: &anyhow::Error) {
    let mut state = state.lock().unwrap();
    if state["status"] == "pending" {
        state["status"] = json!("failed");
        state["error"] = json!(format!(
            "Queue IPC became unavailable before deletion started; the pending job was stopped: {error:#}"
        ));
        state["waitReason"] = Value::Null;
        expiry(&mut state);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn core_failure_maps_only_confirmed_unsubmitted_to_failed() {
        // 投入前確定のCore失敗は元対象保持の原因を残して failed にする。
        let (status, error) = core_failure_state(&recordless::DeleteFailure::NotSubmitted(
            anyhow::anyhow!("Deletion preflight failed; original targets were retained."),
        ));
        assert_eq!(status, "failed");
        assert!(error.starts_with("Deletion was not started;"));
        assert!(error.contains("original targets were retained"));
        assert!(!error.contains("outcome is unknown"));
        // それ以外の失敗は ambiguous と再送禁止を維持する。
        let (status, error) = core_failure_state(&recordless::DeleteFailure::Unknown(
            anyhow::anyhow!("Shell worker failed"),
        ));
        assert_eq!(status, "ambiguous");
        assert!(error.contains("Do not resend deletion."));
        assert!(error.contains("Shell worker failed"));
    }
    #[test]
    fn contact_waits_for_exact_missing_pipe_gap_and_sends_one_status_frame() -> Result<()> {
        let id = uuid::Uuid::new_v4().simple().to_string();
        let first = new_pipe(&id, true)?;
        drop(first);
        let (missing_sender, missing_receiver) = std::sync::mpsc::channel();
        let (ready_sender, ready_receiver) = std::sync::mpsc::channel();
        *CONTACT_MISSING_HOOK.lock().unwrap() = Some((
            id.clone(),
            Box::new(move || {
                missing_sender
                    .send(())
                    .context("Missing-pipe observation receiver disappeared")?;
                ready_receiver
                    .recv_timeout(Duration::from_secs(3))
                    .context("Recreated-pipe permit missing")?;
                Ok(())
            }),
        ));
        std::thread::scope(|scope| -> Result<()> {
            let request_id = id.clone();
            let client = scope.spawn(move || contact(&json!({"jobId":request_id}), false));
            missing_receiver
                .recv_timeout(Duration::from_secs(3))
                .context("Client did not observe ERROR_FILE_NOT_FOUND before reconnection")?;
            let pipe = new_pipe(&id, true)?;
            ready_sender.send(())?;
            accept(pipe.raw())?;
            peer_user(pipe.raw(), true, &security::current_user_sid()?)?;
            anyhow::ensure!(
                pipe_read_frame(pipe.raw(), MAX_FRAME)? == "status",
                "Expected one status frame after reconnection"
            );
            let mut response = initial(&id);
            response["status"] = json!("cancelled");
            expiry(&mut response);
            pipe_write_frame(pipe.raw(), &response)?;
            let result = client
                .join()
                .map_err(|_| anyhow::anyhow!("Contact test client panicked"))??;
            anyhow::ensure!(
                result["status"] == "cancelled",
                "Recreated pipe did not retain the terminal result"
            );
            let mut available = 0;
            let peek = unsafe {
                PeekNamedPipe(
                    pipe.raw(),
                    std::ptr::null_mut(),
                    0,
                    std::ptr::null_mut(),
                    &mut available,
                    std::ptr::null_mut(),
                )
            };
            anyhow::ensure!(
                available == 0 && (peek != 0 || unsafe { GetLastError() } == ERROR_BROKEN_PIPE),
                "A connected request was resent"
            );
            Ok(())
        })?;
        anyhow::ensure!(
            CONTACT_MISSING_HOOK.lock().unwrap().is_none(),
            "Missing-pipe checkpoint was not consumed"
        );
        Ok(())
    }
    #[test]
    fn disconnected_status_peer_preserves_pending_job_and_release_completes() -> Result<()> {
        for immediate_close in [false, true] {
            status_peer_failure_contract(immediate_close)?;
        }
        Ok(())
    }
    fn status_peer_failure_contract(immediate_close: bool) -> Result<()> {
        // TEMPはドライブ文字を問わず、リポジトリとCodex homeの外にある通常のドライブ絶対パスだけを使う。
        let temp = native::path::external_test_temp()?;
        let _parents = native::path::pin_directories(&temp)?;
        let root = temp.join(format!(
            "queue-peer-disconnect-{}",
            uuid::Uuid::new_v4().simple()
        ));
        std::fs::create_dir(&root)?;
        let metadata = root.join("metadata");
        std::fs::create_dir(&metadata)?;
        let target = root.join("owned-target");
        std::fs::write(&target, b"pending peer disconnect must not cancel")?;
        let config = Config {
            path: root.join("config.json"),
            data: crate::config::ConfigData {
                backup_directory: metadata.to_string_lossy().into(),
                ..Default::default()
            },
        };
        let snapshots = Mutex::new(vec![Snapshot::capture(&target, false)?]);
        let holder = native::PinnedFile::open(&target, GENERIC_READ, FILE_SHARE_READ)?;
        let id = uuid::Uuid::new_v4().simple().to_string();
        let owner = security::current_user_sid()?;
        let state = Mutex::new(initial(&id));
        let paths = vec![target.clone()];
        std::thread::scope(|scope| -> Result<()> {
            let execution =
                scope.spawn(|| run_execution(&config, &paths, &snapshots, false, &state));
            let pipe = new_pipe(&id, true)?;
            let name = pipe_name(&id)?;
            let (close_sender, close_receiver) = std::sync::mpsc::channel();
            let client = scope.spawn(move || -> Result<()> {
                let client = unsafe {
                    OwnedHandle::from_raw(CreateFileW(
                        name.as_ptr(),
                        GENERIC_READ | GENERIC_WRITE,
                        0,
                        std::ptr::null(),
                        OPEN_EXISTING,
                        0,
                        std::ptr::null_mut(),
                    ))
                }?;
                write_frame(
                    native::process::duplicate_file(client.raw())?,
                    &json!("status"),
                )?;
                if !immediate_close {
                    let mut byte = 0u8;
                    let mut read = 0;
                    if unsafe {
                        ReadFile(
                            client.raw(),
                            (&mut byte as *mut u8).cast(),
                            1,
                            &mut read,
                            std::ptr::null_mut(),
                        )
                    } == 0
                    {
                        return Err(std::io::Error::last_os_error().into());
                    }
                    assert_eq!(read, 1);
                }
                close_receiver
                    .recv()
                    .map_err(|error| anyhow::anyhow!("Test peer close permit missing: {error}"))?;
                drop(client);
                Ok(())
            });
            accept(pipe.raw())?;
            assert_eq!(pipe_read_frame(pipe.raw(), MAX_FRAME)?, "status");
            peer_user(pipe.raw(), true, &owner)?;
            let error = if immediate_close {
                close_sender.send(())?;
                client.join().unwrap()?;
                let mut written = 0;
                let native_result = unsafe {
                    WriteFile(
                        pipe.raw(),
                        [0u8].as_ptr(),
                        1,
                        &mut written,
                        std::ptr::null_mut(),
                    )
                };
                let native_error = unsafe { GetLastError() };
                assert_eq!(
                    native_result, 0,
                    "Disconnected peer unexpectedly accepted bytes"
                );
                assert!(
                    matches!(
                        native_error,
                        ERROR_BROKEN_PIPE | ERROR_NO_DATA | ERROR_PIPE_NOT_CONNECTED
                    ),
                    "Unexpected actual disconnected peer error {native_error}"
                );
                eprintln!("Actual disconnected peer WriteFile error: {native_error}");
                pipe_write_frame(pipe.raw(), &state.lock().unwrap()).unwrap_err()
            } else {
                pipe_write_frame(pipe.raw(), &state.lock().unwrap())?;
                let error = flush_queue_response(pipe.raw(), &state).unwrap_err();
                close_sender.send(())?;
                client.join().unwrap()?;
                error
            };
            eprintln!(
                "Actual status peer failure: immediateClose={immediate_close}, error={error:#}"
            );
            assert!(
                error
                    .downcast_ref::<native::process::IoHelperInfrastructureFailure>()
                    .is_none(),
                "Peer closure was classified as worker failure: {error:#}"
            );
            assert_eq!(state.lock().unwrap()["status"], "pending");
            unsafe {
                DisconnectNamedPipe(pipe.raw());
            }
            drop(pipe);
            let replacement = new_pipe(&id, false)?;
            let client = scope.spawn(|| contact(&json!({"jobId":id}), false));
            accept(replacement.raw())?;
            assert_eq!(pipe_read_frame(replacement.raw(), MAX_FRAME)?, "status");
            peer_user(replacement.raw(), true, &owner)?;
            pipe_write_frame(replacement.raw(), &state.lock().unwrap())?;
            flush_queue_response(replacement.raw(), &state)?;
            let response = client.join().unwrap()?;
            assert_eq!(response["status"], "pending");
            unsafe {
                DisconnectNamedPipe(replacement.raw());
            }
            assert!(target.exists());
            drop(holder);
            execution.join().unwrap();
            Ok(())
        })?;
        let result = state.lock().unwrap();
        assert_eq!(result["status"], "completed", "{result}");
        assert!(!target.exists());
        assert!(matches!(
            result["result"]["items"][0]["status"].as_str(),
            Some("recycled" | "permanently_deleted")
        ));
        eprintln!(
            "Retained real peer-disconnect/reconnect/release fixture: immediateClose={immediate_close}, {}",
            root.display()
        );
        Ok(())
    }
    #[test]
    fn execution_spawn_failure_is_retained_and_initial_ack_gates_start() -> Result<()> {
        use std::sync::atomic::{AtomicBool, Ordering};
        let id = uuid::Uuid::new_v4().simple().to_string();
        let state = Mutex::new(initial(&id));
        let ran = AtomicBool::new(false);
        std::thread::scope(|scope| {
            let _fault =
                native::process::test_faults::fail_spawn("queue-execution-worker", 1, None);
            assert!(
                start_execution(scope, &state, || {
                    ran.store(true, Ordering::SeqCst);
                })
                .is_none()
            );
        });
        assert!(!ran.load(Ordering::SeqCst));
        assert_eq!(state.lock().unwrap()["status"], "failed");
        assert!(state.lock().unwrap()["expiresUtc"].is_string());
        let owner = security::current_user_sid()?;
        let pipe = new_pipe(&id, true)?;
        std::thread::scope(|scope| -> Result<()> {
            let server = scope.spawn(|| -> Result<()> {
                accept(pipe.raw())?;
                assert_eq!(pipe_read_frame(pipe.raw(), MAX_FRAME)?, "status");
                peer_user(pipe.raw(), true, &owner)?;
                pipe_write_frame(pipe.raw(), &state.lock().unwrap())?;
                flush_response(pipe.raw())
            });
            let response = contact(&json!({"jobId":id}), false)?;
            server.join().unwrap()?;
            assert_eq!(response["status"], "failed");
            assert!(
                response["error"]
                    .as_str()
                    .unwrap()
                    .contains("could not be started")
            );
            Ok(())
        })?;
        for permit_ack in [false, true] {
            let state = Mutex::new(initial(&uuid::Uuid::new_v4().simple().to_string()));
            let ran = AtomicBool::new(false);
            std::thread::scope(|scope| {
                let permit = start_execution(scope, &state, || {
                    ran.store(true, Ordering::SeqCst);
                })
                .unwrap();
                assert!(
                    !ran.load(Ordering::SeqCst),
                    "Deletion started before initial ACK"
                );
                if permit_ack {
                    permit.send(()).unwrap();
                } else {
                    drop(permit);
                }
            });
            assert_eq!(ran.load(Ordering::SeqCst), permit_ack);
        }
        Ok(())
    }
    #[test]
    fn flush_setup_failure_stops_pending_execution_and_never_retries_running() -> Result<()> {
        // TEMPはドライブ文字を問わず、リポジトリとCodex homeの外にある通常のドライブ絶対パスだけを使う。
        let temp = native::path::external_test_temp()?;
        let _parents = native::path::pin_directories(&temp)?;
        let root = temp.join(format!(
            "queue-resource-fault-{}",
            uuid::Uuid::new_v4().simple()
        ));
        std::fs::create_dir(&root)?;
        for handle_failure in [false, true] {
            let target = root.join(if handle_failure {
                "handle-failure.dat"
            } else {
                "spawn-failure.dat"
            });
            std::fs::write(&target, b"pending must survive helper failure")?;
            let snapshots = Mutex::new(vec![Snapshot::capture(&target, false)?]);
            let original =
                native::PinnedFile::open(&target, FILE_READ_ATTRIBUTES | READ_CONTROL, 7)?;
            let before = original.identity()?;
            let holder = native::PinnedFile::open(&target, GENERIC_READ, FILE_SHARE_READ)?;
            let id = uuid::Uuid::new_v4().simple().to_string();
            let pipe = new_pipe(&id, true)?;
            let state = Mutex::new(initial(&id));
            let config = Config {
                path: root.join("config.json"),
                data: Default::default(),
            };
            let paths = vec![target.clone()];
            std::thread::scope(|scope| -> Result<()> {
                let execution =
                    scope.spawn(|| run_execution(&config, &paths, &snapshots, false, &state));
                let _fault = if handle_failure {
                    native::process::test_faults::fail_handle("queue-response-flush")
                } else {
                    native::process::test_faults::fail_spawn("queue-response-flush", 1, None)
                };
                let started = Instant::now();
                assert!(flush_queue_response(pipe.raw(), &state).is_err());
                assert!(started.elapsed() < Duration::from_secs(3));
                assert_eq!(state.lock().unwrap()["status"], "failed");
                drop(holder);
                execution.join().unwrap();
                Ok(())
            })?;
            assert_eq!(original.identity()?, before);
            assert_eq!(
                std::fs::read(&target)?,
                b"pending must survive helper failure"
            );
            assert_eq!(state.lock().unwrap()["status"], "failed");
            let running = Mutex::new(initial(&id));
            running.lock().unwrap()["status"] = json!("running");
            let _fault = native::process::test_faults::fail_spawn("queue-response-flush", 1, None);
            assert!(flush_queue_response(pipe.raw(), &running).is_err());
            assert_eq!(running.lock().unwrap()["status"], "running");
        }
        eprintln!(
            "Retained queue resource-failure fixture: {}",
            root.display()
        );
        Ok(())
    }
    fn accept(pipe: HANDLE) -> Result<()> {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let ok = unsafe { ConnectNamedPipe(pipe, std::ptr::null_mut()) };
            let error = unsafe { GetLastError() };
            if ok == 0 && error == ERROR_PIPE_CONNECTED {
                return Ok(());
            }
            if ok == 0 && error != ERROR_PIPE_LISTENING && error != ERROR_NO_DATA {
                return Err(std::io::Error::from_raw_os_error(error as i32).into());
            }
            if ok == 0 && error == ERROR_NO_DATA {
                unsafe {
                    DisconnectNamedPipe(pipe);
                }
            }
            if Instant::now() >= deadline {
                bail!("Test pipe connection timed out");
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    #[test]
    fn impersonated_enqueue_is_rejected_before_worker_spawn() -> Result<()> {
        let config = Config {
            path: PathBuf::from("D:\\unused-config.json"),
            data: Default::default(),
        };
        let owner = security::current_user_sid()?;
        let token = native::EffectiveToken::capture()?;
        token.run(|| {
            let result = enqueue(&config, &json!({"paths":[]}));
            assert!(
                result
                    .unwrap_err()
                    .to_string()
                    .contains("caller thread is impersonating")
            );
            Ok(())
        })?;
        assert_eq!(security::current_user_sid()?, owner);
        assert!(
            enqueue(&config, &json!({"paths":[]}))
                .unwrap_err()
                .to_string()
                .contains("between 1 and 256")
        );
        Ok(())
    }
    #[test]
    fn framed_json_preserves_unicode_escapes_and_byte_limits() -> Result<()> {
        for value in [json!({"path":"日本語😀\"\n\t\\"}), json!("界".repeat(6000))] {
            let expected = serde_json::to_vec(&value)?;
            let frame = encode_frame(&value, expected.len())?;
            assert_eq!(
                u32::from_le_bytes(frame[..4].try_into()?) as usize,
                expected.len()
            );
            assert_eq!(&frame[4..], expected);
            assert_eq!(parse_unique(&frame[4..])?, value);
            assert!(encode_frame(&value, expected.len() - 1).is_err());
        }
        assert!(encode_frame(&json!(null), 0).is_err());
        assert_eq!(encode_frame(&json!(0), 1)?, b"\x01\0\0\x000");
        Ok(())
    }
    #[test]
    fn retained_result_larger_than_input_limit_is_retrievable() -> Result<()> {
        let id = uuid::Uuid::new_v4().simple().to_string();
        let owner = security::current_user_sid()?;
        let pipe = new_pipe(&id, true)?;
        let mut expected = initial(&id);
        expected["status"] = json!("failed");
        expected["error"] = json!("x".repeat(2 * MAX_FRAME));
        std::thread::scope(|scope| -> Result<()> {
            let server = scope.spawn(|| -> Result<()> {
                accept(pipe.raw())?;
                let request = pipe_read_frame(pipe.raw(), MAX_FRAME)?;
                assert_eq!(request, "status");
                peer_user(pipe.raw(), true, &owner)?;
                pipe_write_frame(pipe.raw(), &expected)?;
                flush_response(pipe.raw())?;
                Ok(())
            });
            let result = contact(&json!({"jobId":id}), false)?;
            let server_result = server
                .join()
                .map_err(|_| anyhow::anyhow!("Test server panicked"))?;
            eprintln!("Large-frame server result: {server_result:?}");
            server_result?;
            assert_eq!(result["status"], "failed", "{result}");
            assert_eq!(result["error"].as_str().map(str::len), Some(2 * MAX_FRAME));
            Ok(())
        })
    }
    #[test]
    fn peer_check_uses_client_effective_token_and_restores_server() -> Result<()> {
        let original_identity = security::effective_identity()?;
        let owner = original_identity.sid.clone();
        let id = uuid::Uuid::new_v4().simple().to_string();
        let pipe = new_pipe(&id, true)?;
        // 同じSIDでもprimaryとは異なる制限付き実効tokenを作り、pipeの実token観測を検査する。
        let restricted = unsafe {
            let mut process_token = std::ptr::null_mut();
            if OpenProcessToken(
                GetCurrentProcess(),
                TOKEN_QUERY | TOKEN_DUPLICATE,
                &mut process_token,
            ) == 0
            {
                return Err(std::io::Error::last_os_error().into());
            }
            let process_token = OwnedHandle::from_raw(process_token)?;
            let text = native::wide(std::ffi::OsStr::new(&owner))?;
            let mut sid = std::ptr::null_mut();
            if ConvertStringSidToSidW(text.as_ptr(), &mut sid) == 0 {
                return Err(std::io::Error::last_os_error().into());
            }
            let restricted_sid = SID_AND_ATTRIBUTES {
                Sid: sid,
                Attributes: 0,
            };
            let mut token = std::ptr::null_mut();
            let ok = CreateRestrictedToken(
                process_token.raw(),
                DISABLE_MAX_PRIVILEGE,
                0,
                std::ptr::null(),
                0,
                std::ptr::null(),
                1,
                &restricted_sid,
                &mut token,
            );
            LocalFree(sid);
            if ok == 0 {
                return Err(std::io::Error::last_os_error().into());
            }
            let primary = OwnedHandle::from_raw(token)?;
            let mut impersonation = std::ptr::null_mut();
            if DuplicateTokenEx(
                primary.raw(),
                TOKEN_QUERY | TOKEN_IMPERSONATE,
                std::ptr::null(),
                SecurityImpersonation,
                TokenImpersonation,
                &mut impersonation,
            ) == 0
            {
                return Err(std::io::Error::last_os_error().into());
            }
            OwnedHandle::from_raw(impersonation)?
        };
        std::thread::scope(|scope| -> Result<()> {
            let client = scope.spawn(|| -> Result<()> {
                unsafe {
                    if SetThreadToken(std::ptr::null(), restricted.raw()) == 0 {
                        return Err(std::io::Error::last_os_error().into());
                    }
                    struct Revert;
                    impl Drop for Revert {
                        fn drop(&mut self) {
                            unsafe {
                                if RevertToSelf() == 0 {
                                    std::process::abort();
                                }
                            }
                        }
                    }
                    let _revert = Revert;
                    let name = pipe_name(&id)?;
                    let deadline = Instant::now() + Duration::from_secs(5);
                    let connection = loop {
                        let raw = CreateFileW(
                            name.as_ptr(),
                            GENERIC_READ | GENERIC_WRITE,
                            0,
                            std::ptr::null(),
                            OPEN_EXISTING,
                            SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION,
                            std::ptr::null_mut(),
                        );
                        if raw != INVALID_HANDLE_VALUE {
                            break OwnedHandle::from_raw(raw)?;
                        }
                        let error = std::io::Error::last_os_error();
                        if error.raw_os_error() != Some(231) || Instant::now() >= deadline {
                            return Err(error.into());
                        }
                        WaitNamedPipeW(name.as_ptr(), 100);
                    };
                    let mut mode = PIPE_READMODE_BYTE | PIPE_NOWAIT;
                    if SetNamedPipeHandleState(
                        connection.raw(),
                        &mut mode,
                        std::ptr::null(),
                        std::ptr::null(),
                    ) == 0
                    {
                        return Err(std::io::Error::last_os_error().into());
                    }
                    pipe_write_frame(connection.raw(), &json!("status"))?;
                    assert_eq!(
                        pipe_read_frame(connection.raw(), MAX_RESPONSE_FRAME)?,
                        "accepted"
                    );
                    Ok(())
                }
            });
            if let Err(error) = accept(pipe.raw()) {
                let client_result = client
                    .join()
                    .map_err(|_| anyhow::anyhow!("Test client panicked"))?;
                eprintln!("Effective-token test client result: {client_result:?}");
                client_result?;
                return Err(error);
            }
            pipe_read_frame(pipe.raw(), MAX_FRAME)?;
            let peer = peer_user(pipe.raw(), true, &owner)?;
            let observed = peer._identity.ok_or_else(|| {
                anyhow::anyhow!("Server did not retain the peer effective identity")
            })?;
            assert!(
                observed.has_restrictions,
                "Server must observe the actual restricted client token rather than its process primary token"
            );
            assert_eq!(observed.sid, owner);
            assert_eq!(
                observed.authentication_id,
                original_identity.authentication_id
            );
            assert_eq!(observed.session_id, original_identity.session_id);
            let restored = security::effective_identity()?;
            assert_eq!(restored.sid, owner);
            assert_eq!(
                restored.has_restrictions,
                original_identity.has_restrictions
            );
            pipe_write_frame(pipe.raw(), &json!("accepted"))?;
            flush_response(pipe.raw())?;
            client
                .join()
                .map_err(|_| anyhow::anyhow!("Test client panicked"))??;
            Ok(())
        })
    }
    #[test]
    fn ipc_failure_stops_pending_job_without_requeue() {
        let state = Mutex::new(initial("0123456789abcdef0123456789abcdef"));
        stop_pending_on_server_failure(&state, &anyhow::anyhow!("injected pipe creation failure"));
        let state = state.lock().unwrap();
        assert_eq!(state["status"], "failed");
        assert!(state["expiresUtc"].is_string());
    }
}
