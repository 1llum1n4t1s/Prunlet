//! hookへの入力はJSONとして渡し、fixture中のコマンドは実行しない。
use anyhow::{Context, Result, bail, ensure};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::{Read, Write},
    os::windows::fs::MetadataExt,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

fn option<'a>(args: &'a [String], name: &str) -> Result<&'a str> {
    let mut found = args.iter().enumerate().filter(|(_, a)| a.as_str() == name);
    let (i, _) = found.next().with_context(|| format!("Missing {name}"))?;
    ensure!(found.next().is_none(), "Duplicate {name}");
    Ok(args
        .get(i + 1)
        .filter(|v| !v.starts_with("--"))
        .with_context(|| format!("Missing value for {name}"))?)
}

/// 検証出力先を作る。ドライブ文字には依存させず、通常のドライブ絶対パス（UNC・デバイスパス不可）で、
/// リポジトリとCodex homeの外にある未使用のディレクトリだけを受け付ける。
pub(crate) fn output_directory(path: &Path) -> Result<()> {
    let raw = path.to_string_lossy();
    let bytes = raw.as_bytes();
    ensure!(
        path.is_absolute()
            && bytes.len() >= 3
            && bytes[0].is_ascii_alphabetic()
            && bytes[1] == b':'
            && bytes[2] == b'\\',
        "Output must be an ordinary drive-absolute path outside the repository and Codex home; UNC and device paths are unsupported"
    );
    ensure!(!path.exists(), "Output directory already exists");
    let parent = path.parent().context("Output parent is missing")?;
    for ancestor in parent.ancestors() {
        let metadata = fs::symlink_metadata(ancestor)?;
        ensure!(
            metadata.is_dir() && metadata.file_attributes() & 0x400 == 0,
            "Output ancestor is not an ordinary directory: {}",
            ancestor.display()
        );
    }
    let parent = fs::canonicalize(parent)?;
    let repo = fs::canonicalize(
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .context("Missing tools directory")?
            .parent()
            .context("Missing repository")?,
    )?;
    let mut excluded_roots = vec![repo];
    // Codex homeは存在する場合だけ除外する。未導入の環境でcanonicalizeが失敗して止まらないようにする。
    let homes = [
        std::env::var_os("USERPROFILE").map(|p| PathBuf::from(p).join(".codex")),
        std::env::var_os("CODEX_HOME").map(PathBuf::from),
    ];
    for home in homes.into_iter().flatten() {
        if home.exists() {
            excluded_roots.push(home);
        }
    }
    let normalized = parent.to_string_lossy().to_lowercase();
    for excluded in excluded_roots {
        let excluded = fs::canonicalize(excluded)?.to_string_lossy().to_lowercase();
        ensure!(
            normalized != excluded && !normalized.starts_with(&(excluded + "\\")),
            "Output inside repository or Codex home is excluded"
        );
    }
    // create_dirは既存対象を上書きせず、親の書込み可否もここで検査する。
    fs::create_dir(path)?;
    Ok(())
}

fn digest(path: &Path) -> Result<String> {
    Ok(hex::encode(Sha256::digest(fs::read(path)?)))
}

fn invoke(executable: &Path, config: &Path, input: &Value) -> Result<(i32, String, String)> {
    let mut child = Command::new(executable)
        .arg("--config")
        .arg(config)
        .arg("hook")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let mut stdin = child.stdin.take().context("Missing hook stdin")?;
    let bytes = serde_json::to_vec(input)?;
    let writer = thread::spawn(move || -> std::io::Result<()> { stdin.write_all(&bytes) });
    let mut stdout = child.stdout.take().context("Missing hook stdout")?;
    let mut stderr = child.stderr.take().context("Missing hook stderr")?;
    let out = thread::spawn(move || {
        let mut b = Vec::new();
        stdout.read_to_end(&mut b).map(|_| b)
    });
    let err = thread::spawn(move || {
        let mut b = Vec::new();
        stderr.read_to_end(&mut b).map(|_| b)
    });
    let deadline = Instant::now() + Duration::from_secs(30);
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status;
        }
        if Instant::now() >= deadline {
            child.kill()?;
            child.wait()?;
            // 子孫がpipeを保持していても30秒の上限を超えて待たない。
            bail!("Hook process timed out after 30 seconds");
        }
        thread::sleep(Duration::from_millis(20));
    };
    if let Err(error) = writer
        .join()
        .map_err(|_| anyhow::anyhow!("Hook input thread panicked"))?
    {
        if error.kind() != std::io::ErrorKind::BrokenPipe {
            return Err(error.into());
        }
    }
    let out = out
        .join()
        .map_err(|_| anyhow::anyhow!("Hook output thread panicked"))??;
    let err = err
        .join()
        .map_err(|_| anyhow::anyhow!("Hook error thread panicked"))??;
    Ok((
        status.code().unwrap_or(-1),
        String::from_utf8_lossy(&out).into_owned(),
        String::from_utf8_lossy(&err).into_owned(),
    ))
}

pub fn run(args: &[String]) -> Result<()> {
    let executable = PathBuf::from(option(args, "--executable")?);
    let output = PathBuf::from(option(args, "--output-directory")?);
    let config = PathBuf::from(option(args, "--config")?);
    let cases_path = PathBuf::from(option(args, "--cases")?);
    ensure!(
        executable.is_absolute() && config.is_absolute() && cases_path.is_absolute(),
        "Input paths must be absolute"
    );
    let cases: Vec<Value> = serde_json::from_slice(&fs::read(cases_path)?)?;
    output_directory(&output)?;
    let sentinel = output.join("hook-sentinel.txt");
    fs::write(&sentinel, b"Hook fixture commands must never execute")?;
    let original = digest(&sentinel)?;
    let mut results = Vec::new();
    for case in cases {
        let name = case["name"].as_str().context("Case name missing")?;
        let command = case["command"]
            .as_str()
            .context("Case command missing")?
            .replace("<FILE>", &sentinel.to_string_lossy());
        let expected = case
            .get("windowsPass")
            .unwrap_or(&case["pass"])
            .as_bool()
            .context("Case expectation missing")?;
        for tool in ["Bash", "exec_command", "functions.exec_command"] {
            let input = if tool == "Bash" {
                json!({"command":command})
            } else {
                json!({"cmd":command,"shell":"/bin/sh"})
            };
            let event = json!({"tool_name":tool,"tool_input":input});
            let (exit, stdout, stderr) = invoke(&executable, &config, &event)?;
            let parsed = serde_json::from_str::<Value>(&stdout).ok();
            let (decision, reason) = match parsed.as_ref() {
                Some(v) if v.as_object().is_some_and(|o| o.is_empty()) => ("pass", ""),
                Some(v) => (
                    v.pointer("/hookSpecificOutput/permissionDecision")
                        .and_then(Value::as_str)
                        .unwrap_or("invalid"),
                    v.pointer("/hookSpecificOutput/permissionDecisionReason")
                        .and_then(Value::as_str)
                        .unwrap_or(""),
                ),
                None => ("invalid", ""),
            };
            let reason_valid = decision == "pass"
                || reason.contains("interpretation=")
                || reason.contains("could not inspect");
            let unchanged = digest(&sentinel).is_ok_and(|value| value == original);
            let passed = exit == 0
                && unchanged
                && reason_valid
                && decision == if expected { "pass" } else { "deny" };
            results.push(json!({"name":name,"tool":tool,"input":event,"expectedPass":expected,"decision":decision,"reason":reason,"reasonValid":reason_valid,"fixtureUnchanged":unchanged,"exitCode":exit,"stderr":stderr,"passed":passed}));
        }
    }
    let failed = results.iter().filter(|r| r["passed"] == false).count();
    let report = json!({"executable":executable,"sha256":digest(&executable)?,"passed":results.len()-failed,"failed":failed,"results":results});
    fs::write(
        output.join("report.json"),
        serde_json::to_vec_pretty(&report)?,
    )?;
    println!("passed={} failed={}", report["passed"], failed);
    for item in report["results"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|item| item["passed"] == false)
    {
        println!(
            "FAIL {} {}: {}",
            item["name"].as_str().unwrap_or(""),
            item["tool"].as_str().unwrap_or(""),
            item["decision"].as_str().unwrap_or("")
        );
    }
    ensure!(failed == 0, "Hook verification failed");
    Ok(())
}
