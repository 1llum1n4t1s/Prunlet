//! セッションは読むだけで、記録されたコマンドは実行しない。
use anyhow::{Context, Result, ensure};
use chrono::{DateTime, Local, NaiveDate, NaiveDateTime, SecondsFormat, TimeZone, Utc};
use regex::Regex;
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    fs,
    io::{BufRead, BufReader},
    os::windows::fs::MetadataExt,
    path::{Path, PathBuf},
};

const LIMITATION: &str = "One path/status/full-error signature per outer output event with Prunlet call context. The context match is lexical; composite exec outputs cannot always be attributed to a nested call. Unattributed DTOs are separate. Nested repeated attempts cannot always be distinguished from mirrored results. DTO observations are not unique operations or proven bugs. Re-read evidence and fixture labels are heuristics. Non-DTO failures are related call candidates, not additional failed items. Truncated or unrecorded outputs cannot be counted.";

fn matches(pattern: &str, text: &str) -> bool {
    Regex::new(pattern).expect("constant regex").is_match(text)
}
// ISO日時の時刻帯省略はJavaScript同様にローカル時刻、日付のみはUTCで解釈する。
fn parse_time(value: &str) -> Option<DateTime<Utc>> {
    if let Ok(time) = DateTime::parse_from_rfc3339(value) {
        return Some(time.with_timezone(&Utc));
    }
    if let Ok(date) = NaiveDate::parse_from_str(value, "%Y-%m-%d") {
        return date.and_hms_opt(0, 0, 0).map(|v| v.and_utc());
    }
    if let Ok(time) = NaiveDateTime::parse_from_str(value, "%Y-%m-%dT%H:%M:%S%.f") {
        return Local
            .from_local_datetime(&time)
            .earliest()
            .map(|v| v.with_timezone(&Utc));
    }
    DateTime::parse_from_rfc2822(value)
        .ok()
        .map(|v| v.with_timezone(&Utc))
}
fn text(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Null => "".into(),
        Value::Object(_) => "[object Object]".into(),
        Value::Array(a) => a.iter().map(text).collect::<Vec<_>>().join(","),
        _ => v.to_string(),
    }
}
fn children(value: &Value) -> Vec<&Value> {
    match value {
        Value::Object(o) => o.values().collect(),
        Value::Array(a) => a.iter().collect(),
        _ => Vec::new(),
    }
}

fn failed_output(value: &Value, depth: usize) -> bool {
    if depth > 12 || value.is_null() {
        return false;
    }
    if value.is_object() || value.is_array() {
        if value["isError"] == true
            || ["exit_code", "exitCode"].iter().any(|k| {
                value
                    .get(*k)
                    .and_then(Value::as_f64)
                    .is_some_and(|n| n != 0.0)
            })
        {
            return true;
        }
        return children(value)
            .into_iter()
            .any(|v| failed_output(v, depth + 1));
    }
    let Some(s) = value.as_str() else {
        return false;
    };
    if let Ok(parsed) = serde_json::from_str::<Value>(s) {
        return failed_output(&parsed, depth + 1);
    }
    if matches(r#"(?i)blocked by|isError"?\s*:\s*true"#, s) {
        return true;
    }
    let re = Regex::new(r#"(?i)(?:exit_code|exitCode)"?\s*:\s*(-?\d+)|exited with code (-?\d+)"#)
        .unwrap();
    re.captures_iter(s).any(|c| {
        c.get(1)
            .or_else(|| c.get(2))
            .is_some_and(|n| n.as_str().parse::<i64>().is_ok_and(|n| n != 0))
    })
}

fn results(value: &Value, depth: usize, emit: &mut impl FnMut(&Value)) {
    if depth > 12 || value.is_null() {
        return;
    }
    if value.is_object() || value.is_array() {
        if value.get("dryRun").is_some_and(Value::is_boolean)
            && value.get("items").is_some_and(Value::is_array)
        {
            emit(value);
        } else {
            for child in children(value) {
                results(child, depth + 1, emit);
            }
        }
    } else if let Some(s) = value.as_str() {
        if let Ok(parsed) = serde_json::from_str::<Value>(s) {
            results(&parsed, depth + 1, emit);
            return;
        }
        for line in s.lines() {
            let line = line.trim();
            if (line.starts_with('{') || line.starts_with('['))
                && let Ok(v) = serde_json::from_str::<Value>(line)
            {
                results(&v, depth + 1, emit);
            }
        }
        // 出力見出しに続く複数行JSONを、文字列内の波括弧とescapeを考慮して抽出する。
        for (start, _) in s.match_indices('{') {
            let tail = &s[start + 1..];
            if !tail
                .trim_start_matches(char::is_whitespace)
                .starts_with('"')
            {
                continue;
            }
            let mut level = 0usize;
            let mut quoted = false;
            let mut escaped = false;
            for (i, c) in s[start..].char_indices() {
                if quoted {
                    if escaped {
                        escaped = false;
                    } else if c == '\\' {
                        escaped = true;
                    } else if c == '"' {
                        quoted = false;
                    }
                } else if c == '"' {
                    quoted = true;
                } else if c == '{' {
                    level += 1;
                } else if c == '}' {
                    level -= 1;
                    if level == 0 {
                        if let Ok(v) = serde_json::from_str::<Value>(&s[start..start + i + 1]) {
                            results(&v, depth + 1, emit);
                        }
                        break;
                    }
                }
            }
        }
    }
}

fn category(error: &str) -> &'static str {
    if matches(
        r"(?i)0x80270021|ACCESS_DENIED|access.*denied|アクセス.*拒否",
        error,
    ) {
        "access_denied"
    } else if matches(r"(?i)sharing violation|共有違反|error.*32\b", error) {
        "sharing_violation"
    } else if matches(
        r"(?i)policy|unsupported|reparse|link-like|protected|reserved|not allowed",
        error,
    ) {
        "safety_refusal"
    } else if matches(r"(?i)confirm|uncertain|ambiguous|不明", error) {
        "unconfirmed"
    } else {
        "other"
    }
}
#[derive(Default)]
struct Scan {
    files: usize,
    events: usize,
    malformed: usize,
    non_dto: usize,
    unattributed: usize,
    counts: BTreeMap<String, usize>,
    signatures: HashSet<String>,
    hits: Vec<Value>,
    related: Vec<Value>,
}
fn walk(root: &Path, start: DateTime<Utc>, end: DateTime<Utc>, scan: &mut Scan) -> Result<()> {
    for entry in fs::read_dir(root)? {
        let entry = entry?;
        let path = entry.path();
        let meta = fs::symlink_metadata(&path)?;
        if meta.file_attributes() & 0x400 != 0 {
            continue;
        }
        if meta.is_dir() {
            walk(&path, start, end, scan)?;
            continue;
        }
        if !meta.is_file() || !entry.file_name().to_string_lossy().ends_with(".jsonl") {
            continue;
        }
        scan.files += 1;
        let mut calls: HashMap<String, (String, String)> = HashMap::new();
        for line in BufReader::new(fs::File::open(&path)?).lines() {
            let line = line?;
            let Ok(record) = serde_json::from_str::<Value>(&line) else {
                scan.malformed += 1;
                continue;
            };
            if record["type"] != "response_item" {
                continue;
            }
            let p = &record["payload"];
            let kind = p["type"].as_str().unwrap_or("");
            let id = text(&p["call_id"]);
            if kind == "function_call" || kind == "custom_tool_call" {
                calls.insert(
                    id,
                    (
                        text(&p["name"]),
                        text(
                            p.get("arguments")
                                .or_else(|| p.get("input"))
                                .unwrap_or(&Value::Null),
                        ),
                    ),
                );
                continue;
            }
            if kind != "function_call_output" && kind != "custom_tool_call_output" {
                continue;
            }
            let Some(time) = record["timestamp"].as_str().and_then(parse_time) else {
                continue;
            };
            if time < start || time > end {
                continue;
            }
            scan.events += 1;
            let call = calls.get(&id);
            let context =
                call.is_some_and(|(name, args)| matches("(?i)prunlet", &format!("{name}{args}")));
            let mut seen = HashSet::new();
            results(&p["output"], 0, &mut |dto| {
                if dto["dryRun"] == true {
                    return;
                }
                for item in dto["items"].as_array().unwrap() {
                    let Some(path_value) = item["path"].as_str() else {
                        continue;
                    };
                    let Some(status) = item["status"]
                        .as_str()
                        .filter(|s| *s == "failed" || *s == "ambiguous")
                    else {
                        continue;
                    };
                    let error = text(&item["error"]);
                    let key = serde_json::to_string(&json!([path_value, status, error])).unwrap();
                    if !seen.insert(key.clone()) {
                        continue;
                    }
                    if !context {
                        scan.unattributed += 1;
                        continue;
                    }
                    scan.signatures.insert(key);
                    let reason = category(&error);
                    *scan.counts.entry(reason.into()).or_default() += 1;
                    let fixture = matches(
                        r"(?i)validation|fixture|verify|recordless|smoke|native-startup|race-v|[\\/]e2e[\\/]|\\run-\d+\\",
                        path_value,
                    );
                    let (name, args) = call.unwrap();
                    scan.hits.push(json!({"time":record["timestamp"],"log":path,"callId":p["call_id"],"tool":name,"context":if matches("(?i)Get-Content|ReadAllText|readFile|scan-prunlet",args) {"evidence_read_candidate"} else {"execution_or_nested"},"path":path_value,"status":status,"reason":reason,"fixture":fixture,"error":error}));
                }
            });
            if seen.is_empty()
                && let Some((name, args)) = call
                && context
                && matches(
                    r"(?i)delete_files|delete_registry|\bregistry-delete\b|\bdelete\b",
                    &format!("{name}{args}"),
                )
                && failed_output(&p["output"], 0)
            {
                scan.non_dto += 1;
                scan.related.push(json!({"time":record["timestamp"],"log":path,"callId":p["call_id"],"tool":name}));
            }
        }
    }
    Ok(())
}
fn scan(root: &Path, end: DateTime<Utc>, days: f64, details: bool) -> Result<Value> {
    ensure!(days.is_finite() && days > 0.0, "--days must be positive");
    let end =
        DateTime::from_timestamp_millis(end.timestamp_millis()).context("Invalid end date")?;
    let start_ms = end.timestamp_millis() as f64 - days * 86_400_000.0;
    ensure!(
        start_ms.is_finite() && start_ms.abs() <= 8_640_000_000_000_000.0,
        "Date interval overflow"
    );
    let start =
        DateTime::from_timestamp_millis(start_ms as i64).context("Date interval overflow")?;
    let mut s = Scan::default();
    walk(root, start, end, &mut s)?;
    let mut out = json!({"start":start.to_rfc3339_opts(SecondsFormat::Millis,true),"end":end.to_rfc3339_opts(SecondsFormat::Millis,true),"files":s.files,"outputEvents":s.events,"malformedLines":s.malformed,"failureObservations":s.hits.len(),"distinctPathStatusErrors":s.signatures.len(),"byReason":s.counts,"nonDtoFailedCalls":s.non_dto,"unattributedDtoItems":s.unattributed,"limitation":LIMITATION});
    if details {
        out["hits"] = json!(s.hits);
        out["relatedFailures"] = json!(s.related);
    }
    Ok(out)
}

fn self_test(root: &Path) -> Result<()> {
    crate::hook::output_directory(root)?;
    let dto = json!({"dryRun":false,"items":[{"path":"D:\\fixture\\a.txt","status":"ambiguous","error":"Access denied {quoted}"}]});
    let row = |payload: Value, timestamp: &str| {
        json!({"type":"response_item","timestamp":timestamp,"payload":payload}).to_string()
    };
    let timestamp = "2026-11-07T00:00:00Z";
    let mut lines = vec![
        row(
            json!({"type":"custom_tool_call","name":"exec","call_id":"a","input":"await tools.exec_command({cmd:\"prunlet.exe delete\"})"}),
            timestamp,
        ),
        row(
            json!({"type":"custom_tool_call_output","call_id":"a","output":[{"type":"input_text","text":format!("Command output:\n{}",serde_json::to_string_pretty(&dto)?)}]}),
            timestamp,
        ),
        row(
            json!({"type":"function_call","call_id":"b","name":"mcp__prunlet__delete_files","arguments":"{}"}),
            timestamp,
        ),
        row(
            json!({"type":"function_call_output","call_id":"b","output":json!({"content":[{"text":dto.to_string()}],"structuredContent":dto}).to_string()}),
            timestamp,
        ),
        row(
            json!({"type":"function_call","call_id":"c","name":"mcp__prunlet__delete_files","arguments":"{}"}),
            timestamp,
        ),
        row(
            json!({"type":"function_call_output","call_id":"c","output":json!({"dryRun":true,"items":dto["items"]}).to_string()}),
            timestamp,
        ),
        row(
            json!({"type":"function_call","call_id":"reordered","name":"mcp__prunlet__delete_files","arguments":"{}"}),
            timestamp,
        ),
        row(
            json!({"type":"function_call_output","call_id":"reordered","output":format!("Header:\n{}",serde_json::to_string_pretty(&json!({"items":dto["items"],"dryRun":false}))?)}),
            timestamp,
        ),
        row(
            json!({"type":"function_call","call_id":"other","name":"another_product","arguments":"{}"}),
            timestamp,
        ),
        row(
            json!({"type":"function_call_output","call_id":"other","output":dto.to_string()}),
            timestamp,
        ),
    ];
    let outputs = [
        json!({"exit_code":1}).to_string().into(),
        serde_json::to_string_pretty(&json!({"exitCode":-1}))?.into(),
        json!({"exit_code":2}),
        "Process exited with code -1".into(),
        json!({"exitCode":0}).to_string().into(),
    ];
    for (index, output) in outputs.into_iter().enumerate() {
        let id = format!("exit{index}");
        lines.push(row(json!({"type":"function_call","call_id":id,"name":"exec","arguments":"prunlet.exe delete"}),timestamp));
        lines.push(row(
            json!({"type":"function_call_output","call_id":id,"output":output}),
            timestamp,
        ));
    }
    lines.push(row(
        json!({"type":"function_call_output","call_id":"d","output":dto.to_string()}),
        "2026-11-01T00:00:00Z",
    ));
    lines.push(row(
        json!({"type":"message","role":"assistant","content":[{"text":dto.to_string()}]}),
        timestamp,
    ));
    lines.push(json!({"type":"event_msg","timestamp":timestamp,"payload":{"type":"agent_message","message":dto.to_string()}}).to_string());
    lines.push("{malformed".into());
    let path = root.join("fixture.jsonl");
    fs::write(&path, lines.join("\n"))?;
    let time = std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_262_304_000);
    fs::OpenOptions::new()
        .write(true)
        .open(&path)?
        .set_times(fs::FileTimes::new().set_accessed(time).set_modified(time))?;
    let end = DateTime::parse_from_rfc3339("2026-11-07T01:00:00Z")?.with_timezone(&Utc);
    let summary = scan(root, end, 3.0, false)?;
    ensure!(
        summary["failureObservations"] == 3
            && summary["distinctPathStatusErrors"] == 1
            && summary["malformedLines"] == 1
            && summary["byReason"]["access_denied"] == 3
            && summary["unattributedDtoItems"] == 1
            && summary["nonDtoFailedCalls"] == 4,
        "Scanner self-test failed: {summary}"
    );
    println!(
        "{}",
        serde_json::to_string_pretty(
            &json!({"passed":true,"checks":["multiline DTO","nested wrappers","same-event deduplication","repeated observation","dry-run exclusion","timestamp exclusion","conversation exclusion","malformed line tolerance","event time independent of mtime"]})
        )?
    );
    Ok(())
}

pub fn run(args: &[String]) -> Result<()> {
    if args.first().is_some_and(|s| s == "--self-test") {
        ensure!(
            args.len() == 2,
            "--self-test requires one new external directory (outside the repository and Codex home)"
        );
        return self_test(Path::new(&args[1]));
    }
    let get = |name: &str| -> Result<Option<&str>> {
        match args.iter().position(|value| value == name) {
            Some(index) => Ok(Some(
                args.get(index + 1)
                    .with_context(|| format!("Missing value for {name}"))?,
            )),
            None => Ok(None),
        }
    };
    let days = get("--days")?.unwrap_or("3").parse::<f64>()?;
    let root = match get("--root")? {
        Some(value) => PathBuf::from(value),
        None => std::env::var_os("USERPROFILE")
            .map(PathBuf::from)
            .context("USERPROFILE missing")?
            .join(".codex")
            .join("sessions"),
    };
    let end = match get("--until")? {
        Some(value) => parse_time(value).context("Invalid --until")?,
        None => Utc::now(),
    };
    let details = args.iter().any(|value| value == "--details");
    println!(
        "{}",
        serde_json::to_string_pretty(&scan(&root, end, days, details)?)?
    );
    Ok(())
}
