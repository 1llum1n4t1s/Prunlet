use super::bounded_input::BoundedInput;
use crate::service::{Backend, Progress};
use anyhow::Result;
use serde_json::{Value, json};
use std::{
    io::{self, Write},
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
    let args = params.get("arguments").cloned().unwrap_or(json!({}));
    if !args.is_object() {
        return Err(invalid("Arguments must be an object."));
    }
    let cmd = match name {
        "delete_files" => {
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
                        &["paths", "dryRun", "recursive", "permanentReservedTree"]
                    },
                )?;
                let paths = args
                    .get("paths")
                    .and_then(Value::as_array)
                    .ok_or_else(|| invalid("Paths must contain 1 to 256 strings."))?;
                if paths.is_empty() || paths.len() > 256 || paths.iter().any(|v| !v.is_string()) {
                    return Err(invalid("Paths must contain 1 to 256 strings."));
                }
                booleans(&args, &["dryRun", "recursive", "permanentReservedTree"])?;
                if args["permanentReservedTree"] == true && args["recursive"] != true {
                    return Err(invalid("permanentReservedTree requires recursive=true."));
                }
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
fn finish(pending: &mut Vec<JoinHandle<Result<()>>>) -> Result<()> {
    for h in pending.drain(..) {
        h.join()
            .map_err(|_| anyhow::anyhow!("MCP request worker panicked"))??;
    }
    Ok(())
}
pub fn run(backend: Arc<dyn Backend>) -> Result<()> {
    let output = Arc::new(Mutex::new(io::stdout()));
    let mut reader = BoundedInput::new(io::stdin());
    let mut initialized = false;
    let mut ready = false;
    let mut pending: Vec<JoinHandle<Result<()>>> = Vec::new();
    let result = (|| -> Result<()> {
        while let Some(line) = reader.read_stdin_line()? {
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
                if method == "tools/call" && ready && params["name"] == "delete_files" {
                    // MCP要求枠は4つ。Core側のprocess共通worker上限とは独立。
                    if pending.len() >= 4 {
                        let h = pending.remove(0);
                        h.join()
                            .map_err(|_| (-32603, "MCP request worker panicked".into()))?
                            .map_err(|e| (-32603, e.to_string()))?;
                    }
                    let b = backend.clone();
                    let o = output.clone();
                    let i = id.clone();
                    pending.push(thread::spawn(move || {
                        let v = match call(&*b, &params, &o) {
                            Ok(r) => json!({"jsonrpc":"2.0","id":i,"result":r}),
                            Err((c, m)) => error(i, c, m),
                        };
                        write(&o, &v)
                    }));
                    return Ok(Value::Null);
                }
                if method == "tools/call" {
                    finish(&mut pending).map_err(|e| (-32603, e.to_string()))?;
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
    let workers = finish(&mut pending);
    result.and(workers)
}
const INSTRUCTIONS: &str = "Use delete_files for explicitly authorized absolute native paths. Files normally go to Windows Recycle Bin or macOS Trash without Prunlet operation records. An ordinary file with a Windows reserved final name is permanently deleted after identity checks without using the bin; dry-run reports would_permanently_delete. If Windows reports that an ordinary item is too large for the bin and its original identity is confirmed, Prunlet attempts permanent deletion. Prunlet may also permanently delete a normal item only when Windows reports the bin unavailable, the effective-user per-volume immediate-delete setting is confirmed again immediately before deletion, and original identity is unchanged. Other recycling failures never trigger permanent deletion. Dry-run cannot predict an ordinary item's bin-size outcome. Confirmed removal returns permanently_deleted. Other dry-runs return would_recycle, completed bin moves return recycled, and missing targets return already_absent. Failed or ambiguous results are not success. For ambiguous results, inspect the original source and OS bin without resending deletion. Set recursive=true for directory contents. On Windows, permanentReservedTree=true explicitly selects permanent deletion of a normal directory root with an actual reserved-name descendant, with recursive=true and at most 4095 total entries across all roots. It is synchronous-only, defaults to false, never calls the bin, and is never selected as a fallback after failure. Metadata and legacy recovery storage remain protected. Never expand wildcards or follow link targets. Hard links share surviving content. On macOS, queued deletion waits only for cooperating advisory flock holders; merely opening a file or mapping a dylib does not delay deletion. Registry tools are Windows-only and unsupported on macOS. They require explicit view 32 or 64, full ACL snapshots and transactions, without automatic elevation or nontransactional fallback. Registry retention defaults to 7 days and 1 GiB and never applies to the OS bin. Existing host approvals and policies still apply.";
fn tools() -> Value {
    serde_json::from_str(include_str!("tools.json")).expect("embedded MCP schemas")
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
