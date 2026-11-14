use super::bounded_input::{BoundedInput, is_invalid_utf8};
use crate::service::{Backend, Progress};
use anyhow::Result;
use serde_json::{Value, json};
use std::{
    io::{self, Write},
    panic::{AssertUnwindSafe, catch_unwind},
    sync::{Arc, Mutex},
    thread::{self, JoinHandle},
};

type RpcResult = std::result::Result<Value, (i32, String)>;
type Output = Arc<Mutex<io::Stdout>>;
fn write(out: &Output, value: &Value) -> Result<()> {
    let mut o = out
        .lock()
        .map_err(|_| anyhow::anyhow!("Output lock poisoned"))?;
    serde_json::to_writer(&mut *o, value)?;
    writeln!(o)?;
    o.flush()?;
    Ok(())
}
fn error(id: Value, code: i32, message: impl Into<String>) -> Value {
    json!({"jsonrpc":"2.0","id":id,"error":{"code":code,"message":message.into()}})
}
fn invalid(message: impl Into<String>) -> (i32, String) {
    (-32602, message.into())
}
fn string<'a>(v: &'a Value, name: &str) -> std::result::Result<&'a str, (i32, String)> {
    v.get(name)
        .and_then(Value::as_str)
        .filter(|s| !s.trim().is_empty())
        .ok_or_else(|| invalid(format!("Missing or invalid string: {name}")))
}
fn extra(v: &Value, allowed: &[&str]) -> std::result::Result<(), (i32, String)> {
    if v.as_object()
        .is_none_or(|o| o.keys().any(|k| !allowed.contains(&k.as_str())))
    {
        Err(invalid("Unexpected argument property."))
    } else {
        Ok(())
    }
}
fn booleans(v: &Value, names: &[&str]) -> std::result::Result<(), (i32, String)> {
    for n in names {
        if v.get(*n).is_some_and(|v| !v.is_boolean()) {
            return Err(invalid(format!("{n} must be boolean.")));
        }
    }
    Ok(())
}
fn access(v: &Value) -> std::result::Result<(), (i32, String)> {
    if v.get("accessMode")
        .is_some_and(|v| !matches!(v.as_str(), Some("normal" | "backupRestore")))
    {
        Err(invalid("AccessMode must be normal or backupRestore."))
    } else {
        Ok(())
    }
}
fn command(params: &Value) -> std::result::Result<(&'static str, Value), (i32, String)> {
    let name = string(params, "name")?;
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    if name != "delete_files" {
        return Err(invalid("Only delete_files is supported on this platform."));
    }
    let args = params.get("arguments").cloned().unwrap_or(json!({}));
    if !args.is_object() {
        return Err(invalid("Arguments must be an object."));
    }
    let cmd = match name {
        "delete_files" => {
            #[cfg(target_os = "linux")]
            extra(&args, &["paths", "dryRun", "recursive"])?;
            let action = args
                .get("action")
                .map(|v| {
                    v.as_str()
                        .ok_or_else(|| invalid("Action must be a string."))
                })
                .transpose()?;
            if matches!(action, Some("status" | "cancel")) {
                extra(&args, &["action", "jobId"])?;
                string(&args, "jobId")?;
                if action == Some("status") {
                    "delete-queue-status"
                } else {
                    "delete-queue-cancel"
                }
            } else {
                if action.is_some() && action != Some("enqueue") {
                    return Err(invalid(
                        "Action must be enqueue, status or cancel when specified.",
                    ));
                }
                extra(
                    &args,
                    if action.is_some() {
                        &["action", "paths", "recursive"]
                    } else {
                        &["paths", "dryRun", "recursive"]
                    },
                )?;
                let paths = args
                    .get("paths")
                    .and_then(Value::as_array)
                    .ok_or_else(|| invalid("Paths must contain 1 to 256 strings."))?;
                if paths.is_empty() || paths.len() > 256 || paths.iter().any(|v| !v.is_string()) {
                    return Err(invalid("Paths must contain 1 to 256 strings."));
                }
                booleans(&args, &["dryRun", "recursive"])?;
                if action.is_some() {
                    "delete-queue"
                } else {
                    "delete"
                }
            }
        }
        "delete_registry" => {
            extra(
                &args,
                &[
                    "path",
                    "view",
                    "valueName",
                    "recursive",
                    "dryRun",
                    "accessMode",
                ],
            )?;
            string(&args, "path")?;
            if !matches!(string(&args, "view")?, "32" | "64") {
                return Err(invalid("View must be 32 or 64."));
            }
            booleans(&args, &["recursive", "dryRun"])?;
            access(&args)?;
            if let Some(v) = args.get("valueName") {
                if !v.is_string() {
                    return Err(invalid(
                        "ValueName must be a string, including an empty string for the default value.",
                    ));
                }
                if args["recursive"] == true {
                    return Err(invalid("Recursive cannot be combined with valueName."));
                }
            }
            "registry-delete"
        }
        "restore_registry" => {
            extra(&args, &["operationId", "accessMode"])?;
            string(&args, "operationId")?;
            access(&args)?;
            "registry-restore"
        }
        "reconcile_registry" => {
            extra(&args, &["operationId"])?;
            string(&args, "operationId")?;
            "registry-reconcile"
        }
        "list_operations" => {
            extra(&args, &[])?;
            "operations"
        }
        _ => return Err(invalid(format!("Unknown tool: {name}"))),
    };
    Ok((cmd, args))
}
fn has_errors(v: &Value) -> bool {
    crate::result_status::has_direct_error(v)
        || v.get("items")
            .and_then(Value::as_array)
            .is_some_and(|a| a.iter().any(has_errors))
        || v.get("result").is_some_and(has_errors)
}

#[cfg(test)]
mod worker_tests {
    use super::*;
    use std::{
        sync::atomic::{AtomicUsize, Ordering},
        time::Duration,
    };

    #[test]
    fn finish_joins_every_worker_before_keeping_the_first_error() {
        let done = Arc::new(AtomicUsize::new(0));
        let mut pending: Vec<JoinHandle<Result<()>>> = Vec::new();
        pending.push(thread::spawn(|| Err(anyhow::anyhow!("write failed"))));
        for _ in 0..3 {
            let done = done.clone();
            pending.push(thread::spawn(move || {
                // 先頭のworkerが失敗した後でも完了まで待たれることを確かめるため、遅れて終わらせる。
                thread::sleep(Duration::from_millis(150));
                done.fetch_add(1, Ordering::SeqCst);
                Ok(())
            }));
        }
        let mut deferred = None;
        finish(&mut pending, &mut deferred);
        assert!(pending.is_empty());
        assert_eq!(done.load(Ordering::SeqCst), 3);
        assert_eq!(deferred.expect("first error").to_string(), "write failed");
    }

    #[test]
    fn worker_panic_is_an_error_and_does_not_hide_later_workers() {
        let done = Arc::new(AtomicUsize::new(0));
        let mut pending: Vec<JoinHandle<Result<()>>> = Vec::new();
        pending.push(thread::spawn(|| panic!("worker panic for test")));
        let flag = done.clone();
        pending.push(thread::spawn(move || {
            thread::sleep(Duration::from_millis(100));
            flag.fetch_add(1, Ordering::SeqCst);
            Ok(())
        }));
        let mut deferred = None;
        finish(&mut pending, &mut deferred);
        assert_eq!(done.load(Ordering::SeqCst), 1);
        assert_eq!(
            deferred.expect("panic error").to_string(),
            "MCP request worker panicked"
        );
    }
}

#[cfg(test)]
mod result_tests {
    use super::*;

    #[test]
    fn mcp_keeps_its_own_result_and_items_recursion() {
        assert!(has_errors(
            &json!({"items":[{"result":{"status":"restore_failed"}}]})
        ));
        assert!(has_errors(
            &json!({"result":{"items":[{"error":"denied"}]}})
        ));
        for value in [
            json!({"operations":[{"status":"failed"}]}),
            json!({"registryReady":false}),
            json!({"capacityKnown":false,"complete":false}),
            json!({"items":[{"status":"would_recycle"}]}),
        ] {
            assert!(!has_errors(&value), "{value}");
        }
    }
}
fn call(backend: &dyn Backend, params: &Value, out: &Output) -> RpcResult {
    let (cmd, args) = command(params)?;
    let state = Arc::new(Mutex::new((true, 0u64)));
    let token = params
        .pointer("/_meta/progressToken")
        .filter(|v| v.is_string() || v.as_i64().is_some())
        .cloned();
    let progress: Option<Progress> = token.map(|token| {
        let state = state.clone();
        let out = out.clone();
        Arc::new(move |value: Value| {
            if let Ok(mut s) = state.lock() {
                if !s.0 {
                    return;
                }
                s.1 += 1;
                let mut p = value.as_object().cloned().unwrap_or_default();
                p.insert("progressToken".into(), token.clone());
                p.insert("progress".into(), json!(s.1));
                let _ = write(
                    &out,
                    &json!({"jsonrpc":"2.0","method":"notifications/progress","params":p}),
                );
            }
        }) as Progress
    });
    let result = backend.execute(cmd, &args, progress);
    if let Ok(mut s) = state.lock() {
        s.0 = false;
    }
    Ok(match result {
        Ok(v) => {
            json!({"content":[{"type":"text","text":v.to_string()}],"isError":has_errors(&v),"structuredContent":v})
        }
        Err(e) => json!({"content":[{"type":"text","text":e.to_string()}],"isError":true}),
    })
}
/// workerの終了を待ち、結果を返す。panicはエラーとして扱う。
fn join_worker(handle: JoinHandle<Result<()>>) -> Result<()> {
    handle
        .join()
        .map_err(|_| anyhow::anyhow!("MCP request worker panicked"))?
}
/// 受付済みの全workerを最後まで待つ。最初のエラーは`deferred`へ保持し、途中で打ち切らない。
/// 1件の応答書込み失敗（クライアント切断）で残りのJoinHandleをdetachすると、`main`のprocess終了で
/// 実行中の削除が途中で打ち切られるため、エラーを見ても必ず全員をjoinする。
fn finish(pending: &mut Vec<JoinHandle<Result<()>>>, deferred: &mut Option<anyhow::Error>) {
    for handle in pending.drain(..) {
        if let Err(error) = join_worker(handle) {
            deferred.get_or_insert(error);
        }
    }
}
pub fn run(backend: Arc<dyn Backend>) -> Result<()> {
    let output = Arc::new(Mutex::new(io::stdout()));
    let mut reader = BoundedInput::new(io::stdin());
    let mut initialized = false;
    let mut ready = false;
    let mut pending: Vec<JoinHandle<Result<()>>> = Vec::new();
    // worker側で起きた最初のエラー。無関係な要求の応答には使わず、終了時にまとめて返す。
    let mut deferred: Option<anyhow::Error> = None;
    let result = (|| -> Result<()> {
        loop {
            let line = match reader.read_stdin_line() {
                Ok(Some(line)) => line,
                Ok(None) => break,
                // 不正なUTF-8の行は区切りまで消費済み。JSON-RPCのparse error（idはnull）で拒否し、
                // 次の行から処理を続ける。OS・コンソール由来を含む他のI/Oエラーは従来どおり終了する。
                Err(e) if is_invalid_utf8(&e) => {
                    write(
                        &output,
                        &error(Value::Null, -32700, "Request is not valid UTF-8."),
                    )?;
                    continue;
                }
                Err(e) => return Err(e.into()),
            };
            if line.whitespace {
                continue;
            }
            let mut id = Value::Null;
            let response = (|| -> RpcResult {
                if line.exceeds_limit {
                    return Err((-32600, "Request exceeds 1 MiB.".into()));
                }
                let request: Value =
                    serde_json::from_str(&line.text).map_err(|e| (-32700, e.to_string()))?;
                if !request.is_object() {
                    return Err((-32600, "Expected a JSON-RPC object.".into()));
                }
                if let Some(v) = request.get("id") {
                    if !v.is_string() && !v.is_number() {
                        return Err((-32600, "Request id must be a string or number.".into()));
                    }
                    id = v.clone();
                }
                let method = request
                    .get("method")
                    .and_then(Value::as_str)
                    .ok_or_else(|| (-32600, "Invalid JSON-RPC request.".into()))?;
                if request["jsonrpc"] != "2.0" {
                    return Err((-32600, "Invalid JSON-RPC request.".into()));
                }
                if request.get("id").is_none() {
                    if method == "notifications/initialized" && initialized {
                        ready = true;
                    }
                    return Ok(Value::Null);
                }
                if duplicate_access_mode(&line.text) {
                    return Err(invalid("Duplicate accessMode is refused."));
                }
                let params = request.get("params").cloned().unwrap_or(Value::Null);
                if method == "tools/call" && deferred.is_some() {
                    // 応答の書込みが既に失敗している（クライアント切断）場合、結果を返せない新しい操作は
                    // 実行しない。受付済みの要求は`finish`で最後まで完了させる契約を維持する。
                    return Err((
                        -32603,
                        "MCP output is no longer writable; the request was not executed.".into(),
                    ));
                }
                if method == "tools/call" && ready && params["name"] == "delete_files" {
                    // MCP要求枠は4つ。Core側のprocess共通worker上限とは独立。
                    if pending.len() >= 4 {
                        // 最古workerの失敗は今回の要求と無関係なので、保持して終了時に返す。
                        let handle = pending.remove(0);
                        if let Err(error) = join_worker(handle) {
                            deferred.get_or_insert(error);
                        }
                    }
                    let b = backend.clone();
                    let o = output.clone();
                    let i = id.clone();
                    pending.push(thread::spawn(move || {
                        // backendのpanicでも当該idへエラー応答を返し、クライアントを待たせ続けない。
                        let v = match catch_unwind(AssertUnwindSafe(|| call(&*b, &params, &o))) {
                            Ok(Ok(r)) => json!({"jsonrpc":"2.0","id":i,"result":r}),
                            Ok(Err((c, m))) => error(i, c, m),
                            Err(_) => error(i, -32603, "MCP request worker panicked"),
                        };
                        write(&o, &v)
                    }));
                    return Ok(Value::Null);
                }
                if method == "tools/call" {
                    // 以前のworkerの失敗はこの要求の失敗ではないため、保持だけして続行する。
                    finish(&mut pending, &mut deferred);
                }
                let result = match method {
                    "ping" => json!({}),
                    "initialize" => {
                        if initialized {
                            return Err((-32600, "Already initialized.".into()));
                        }
                        let version = string(&params, "protocolVersion")?;
                        initialized = true;
                        json!({"protocolVersion":if ["2025-11-25","2025-06-18","2024-11-05"].contains(&version){version}else{"2025-11-25"},"capabilities":{"tools":{"listChanged":false}},"serverInfo":{"name":"prunlet","title":"Prunlet","version":crate::VERSION},"instructions":INSTRUCTIONS})
                    }
                    _ if !ready => {
                        return Err((
                            -32600,
                            "Initialize and send notifications/initialized first.".into(),
                        ));
                    }
                    "tools/list" => json!({"tools":tools()}),
                    "tools/call" => call(&*backend, &params, &output)?,
                    _ => return Err((-32601, format!("Unknown method: {method}"))),
                };
                Ok(json!({"jsonrpc":"2.0","id":id,"result":result}))
            })();
            match response {
                Ok(v) if !v.is_null() => write(&output, &v)?,
                Err((c, m)) => write(&output, &error(id, c, m))?,
                _ => {}
            }
        }
        Ok(())
    })();
    // stdin EOFでも受付済みの要求は完了させる。
    finish(&mut pending, &mut deferred);
    result.and(deferred.map_or(Ok(()), Err))
}
#[cfg(windows)]
const INSTRUCTIONS: &str = r#"Use delete_files for authorized absolute Windows files and empty directories without a target directory allowlist. Set recursive=true for directory contents. Files and directories normally go to the Windows Recycle Bin without Prunlet operation records. An ordinary file with a Windows reserved final name is permanently deleted after identity checks without using the bin; dry-run reports would_permanently_delete. Reserved-name directories and links are rejected. If Windows reports that an item is too large for the bin and its original identity is confirmed, Prunlet attempts to permanently delete its original name. Only confirmed removal returns permanently_deleted; an uncertain attempt returns ambiguous. A permanently deleted name cannot be restored from the bin. On a volume whose confirmed immediate-delete setting means the bin is unavailable, an item may also be permanently deleted after the same identity checks; its status is permanently_deleted, never recycled. Other recycling failures do not trigger permanent deletion. Dry-run cannot predict an ordinary item's bin-size outcome. File results have no operationId. For ambiguous results, do not resend deletion; inspect the source and Windows Recycle Bin. Windows controls bin retention and users may empty it. Metadata and legacy volume recovery directories and their ancestors remain protected. Links are handled without following their targets. Hard links share content with surviving aliases. Prunlet retention and capacity settings default to 7 days and 1 GiB for registry snapshots only, never for the Windows bin. list_operations lists registry recovery only. Use delete_registry for explicitly authorized local keys/values with required view 32 or 64, and restore_registry for their operationId. Empty valueName selects the default value; omitted valueName selects the key. Full key ACL snapshots require SeSecurityPrivilege; no automatic elevation or nontransactional fallback. Existing host approvals and policies still apply."#;
#[cfg(target_os = "macos")]
const INSTRUCTIONS: &str = "Use delete_files for authorized absolute macOS paths. Set recursive=true for directory contents. Files move to the macOS Trash without operation records. Links are handled without following their targets. Inspect the source and Trash after ambiguous results. The queue waits for cooperative flock locks.";
#[cfg(target_os = "linux")]
const INSTRUCTIONS: &str = "Use delete_files for authorized absolute Linux paths. Set recursive=true for directory contents. Items move to the freedesktop home Trash on the same mount. Links are handled without following their targets. Inspect the source and Trash after ambiguous results.";
fn tools() -> Value {
    let tools: Vec<Value> =
        serde_json::from_str(include_str!("tools.json")).expect("embedded MCP schemas");
    #[cfg(windows)]
    return Value::Array(tools);
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    {
        let mut file_tool = tools
            .into_iter()
            .find(|tool| tool["name"] == "delete_files")
            .expect("embedded file tool");
        file_tool["description"] = json!(INSTRUCTIONS);
        #[cfg(target_os = "linux")]
        {
            let schema = &mut file_tool["inputSchema"];
            let properties = schema["properties"].as_object_mut().expect("file tool properties");
            properties.remove("action");
            properties.remove("jobId");
            let schema = schema.as_object_mut().expect("file tool schema");
            schema.remove("oneOf");
            schema.insert("required".into(), json!(["paths"]));
        }
        json!([file_tool])
    }
}

// Valueへ変換すると同名propertyが失われるため、権限指定の重複を元JSONで検査する。
fn duplicate_access_mode(text: &str) -> bool {
    let bytes = text.as_bytes();
    let mut stack = Vec::<bool>::new();
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'{' => stack.push(false),
            b'}' => {
                stack.pop();
            }
            b'"' => {
                let start = i;
                i += 1;
                while i < bytes.len() {
                    if bytes[i] == b'\\' {
                        i += 2;
                        continue;
                    }
                    if bytes[i] == b'"' {
                        break;
                    }
                    i += 1;
                }
                let end = (i + 1).min(bytes.len());
                let mut next = end;
                while next < bytes.len() && bytes[next].is_ascii_whitespace() {
                    next += 1;
                }
                if bytes.get(next) == Some(&b':')
                    && serde_json::from_str::<String>(&text[start..end])
                        .is_ok_and(|key| key == "accessMode")
                {
                    if let Some(seen) = stack.last_mut() {
                        if *seen {
                            return true;
                        }
                        *seen = true;
                    }
                }
            }
            _ => {}
        }
        i += 1;
    }
    false
}

#[cfg(test)]
mod access_mode_tests {
    use super::duplicate_access_mode;

    #[test]
    fn refuses_duplicate_access_mode_in_the_same_object() {
        for text in [
            r#"{"accessMode":"normal","accessMode":"backupRestore"}"#,
            r#"{"arguments":{"accessMode":"normal","\u0061ccessMode":"backupRestore"}}"#,
            r#"{"accessMode":"normal","child":{},"accessMode":"backupRestore"}"#,
        ] {
            assert!(duplicate_access_mode(text), "{text}");
        }
    }

    #[test]
    fn preserves_separate_access_modes_and_unrelated_duplicate_keys() {
        for text in [
            r#"{"accessMode":"normal","child":{"accessMode":"backupRestore"}}"#,
            r#"{"children":[{"accessMode":"normal"},{"accessMode":"backupRestore"}]}"#,
            r#"{"accessMode":"normal","text":"\"accessMode\": \"backupRestore\"","text":"note"}"#,
        ] {
            assert!(!duplicate_access_mode(text), "{text}");
        }
    }
}
