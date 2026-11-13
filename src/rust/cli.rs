use std::{
    collections::HashSet,
    ffi::OsString,
    io::{self, Write},
    path::{Path, PathBuf},
    sync::Arc,
};

use anyhow::{Result, bail, ensure};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::{
    config::{Config, ConfigData},
    platform,
    service::{Backend, Runtime},
};

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Host {
    Cli,
    Hook,
    Maintenance,
}

/// hookの起動失敗をPreToolUseの拒否JSONとして返す。
/// hookの呼出し元はstdoutのJSONだけを判定に使うため、起動前の失敗もerror JSON・exit 1ではなく
/// 理由付きの拒否・exit 0にして、検査されないまま素通しや判定不能にならないようにする。
fn hook_start_denied(reason: &str) -> i32 {
    eprintln!("Prunlet hook: {reason}");
    let value = json!({"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":format!("Prunlet hook could not start: {reason}")}});
    let _ = write_json(&value);
    0
}

pub fn run(args: Vec<OsString>, mut host: Host) -> i32 {
    // `--config <path> hook`の起動か。Unicode変換や設定・起動処理より前に判定し、
    // それらの失敗もhook形式の拒否で返す（Windowsのprunlet-hook入口と同じ扱い）。
    let hook_command = args.get(2).is_some_and(|a| a == "hook");
    if host == Host::Cli
        && std::env::current_exe()
            .ok()
            .and_then(|p| p.file_name().map(|s| s.to_string_lossy().into_owned()))
            .is_some_and(|n| {
                matches!(
                    n.to_ascii_lowercase().as_str(),
                    "prunlet-hook.exe" | "prunlet-hook"
                )
            })
    {
        host = Host::Hook;
    }
    let args: Result<Vec<String>> = args
        .into_iter()
        .map(|v| {
            v.into_string()
                .map_err(|_| anyhow::anyhow!("Arguments must be valid Unicode."))
        })
        .collect();
    let args = match args {
        Ok(v) => v,
        Err(e) if host == Host::Hook || hook_command => return hook_start_denied(&e.to_string()),
        Err(e) => {
            write_error(&e, false);
            return 1;
        }
    };
    let mcp = args.len() >= 3 && args[0] == "--config" && args[2] == "mcp";
    if host == Host::Hook {
        if args.len() != 5
            || args[0] != "--config"
            || args[2] != "hook"
            || args[3] != "--cli-executable"
            || !Path::new(&args[1]).is_absolute()
            || !Path::new(&args[4]).is_absolute()
        {
            return hook_start_denied("Invalid Prunlet hook arguments.");
        }
        return crate::protocol::hook::run(Path::new(&args[1]), Path::new(&args[4]));
    }
    if host == Host::Maintenance
        && !(args.len() == 4
            && args[0] == "--config"
            && args[2] == "maintain"
            && args[3] == "--apply")
    {
        return 2;
    }
    match run_inner(&args) {
        Ok(code) => code,
        // hook分岐より前の`--config`・絶対パス検査、非Windowsのstartup::enter、hook引数検査の失敗。
        // hook::run自体は常にOkを返すため、ここに来るのは起動前の失敗だけである。
        Err(e) if hook_command => hook_start_denied(&e.to_string()),
        Err(e) => {
            write_error(&e, mcp);
            1
        }
    }
}

fn write_json(value: &Value) -> Result<()> {
    let stdout = io::stdout();
    let mut out = stdout.lock();
    serde_json::to_writer(&mut out, value)?;
    writeln!(out)?;
    out.flush()?;
    Ok(())
}

fn write_error(error: &anyhow::Error, stderr: bool) {
    if stderr {
        eprintln!("{error}");
        return;
    }
    let kind = if error.downcast_ref::<serde_json::Error>().is_some() {
        "JsonException"
    } else if let Some(e) = error.downcast_ref::<io::Error>() {
        if e.kind() == io::ErrorKind::PermissionDenied {
            "UnauthorizedAccessException"
        } else {
            "IOException"
        }
    } else {
        "ArgumentException"
    };
    let _ = write_json(&json!({"error":error.to_string(),"type":kind}));
}

fn run_inner(args: &[String]) -> Result<i32> {
    #[cfg(target_os = "linux")]
    if args == ["--linux-build-info"] {
        write_json(&platform::linux::startup::build_info())?;
        return Ok(0);
    }
    #[cfg(target_os = "macos")]
    if args == ["--macos-build-info"] {
        write_json(&platform::macos::startup::build_info())?;
        return Ok(0);
    }
    #[cfg(target_os = "macos")]
    if let [option, path] = args
        && option == "--install-macos"
    {
        write_json(&platform::macos::startup::install(Path::new(path))?)?;
        return Ok(0);
    }
    #[cfg(target_os = "macos")]
    if let [option, path] = args
        && option == "--package-macos-release"
    {
        write_json(&platform::macos::startup::package(Path::new(path))?)?;
        return Ok(0);
    }
    #[cfg(not(target_os = "linux"))]
    if args == ["--startup-update-protocol"] {
        let protocol = json!({"protocol":1,"storageEpoch":1});
        write_json(&protocol)?;
        return Ok(0);
    }
    if args.is_empty() || args == ["--help"] || args == ["help"] {
        println!("{HELP}");
        return Ok(0);
    }
    ensure!(
        args.len() >= 3 && args[0] == "--config",
        "Specify --config <absolute-json-path> before the command."
    );
    let config_path = PathBuf::from(&args[1]);
    ensure!(config_path.is_absolute(), "Config path must be absolute.");
    let command = args[2].as_str();
    let tail = &args[3..];
    #[cfg(target_os = "macos")]
    let _installation_lease = platform::macos::startup::enter(&config_path, command, args)?;
    #[cfg(target_os = "linux")]
    let _installation_lease = platform::linux::startup::enter(&config_path, command, args)?;
    if command == "hook" {
        ensure!(
            tail.is_empty() || (tail.len() == 2 && tail[0] == "--hook-script"),
            "Use hook with no arguments, or legacy --hook-script <path>."
        );
        let executable = std::env::current_exe()?;
        return Ok(crate::protocol::hook::run(&config_path, &executable));
    }
    #[cfg(windows)]
    if !command.starts_with("__begin-")
        && !matches!(
            command,
            "__check-startup-budget"
                | "__download-published-package"
                | "__prepare-published-package"
                | "__apply-startup-update"
                | "__apply-startup-integration"
                | "__confirm-startup-integration"
        )
    {
        crate::update::ensure_ready(&config_path)?;
    }
    if command == "init" {
        return initialize(&config_path, tail);
    }
    let config = Config::load(&config_path)?;
    if command == "validate-config" {
        ensure!(tail.is_empty(), "Validate-config accepts no arguments.");
        write_json(&json!({"valid":true}))?;
        return Ok(0);
    }
    let runtime = Arc::new(if command == "mcp" {
        Runtime::for_mcp(config)?
    } else {
        Runtime::new(config)
    });
    if command == "mcp" {
        ensure!(tail.is_empty(), "MCP accepts no arguments.");
        // Store版PowerShellのlauncherから起動された場合でも、launcherのjobへ入って寿命を揃える。
        // 入れなくてもMCPは起動する（待機キューの受付だけが所属確認で拒否される）。
        #[cfg(windows)]
        if let Err(error) = crate::platform::windows::process::join_mcp_launcher_job() {
            eprintln!("Prunlet MCP did not join its launcher job: {error}");
        }
        crate::protocol::mcp::run(runtime)?;
        return Ok(0);
    }
    let params = parse_command(command, tail)?;
    let value = runtime.execute(
        if command == "restore" {
            "registry-restore"
        } else {
            command
        },
        &params,
        None,
    )?;
    if matches!(command, "__delete-queue-worker" | "registry-session") {
        return Ok(0);
    }
    let failed = command_failed(command, &value);
    write_json(&value)?;
    Ok(i32::from(failed))
}

fn initialize(path: &Path, args: &[String]) -> Result<i32> {
    let mut roots = Vec::new();
    let mut backup = None;
    let mut i = 0;
    while i < args.len() {
        ensure!(i + 1 < args.len(), "Init options require values.");
        match args[i].as_str() {
            "--allowed-root" => roots.push(args[i + 1].clone()),
            "--backup-directory" if backup.is_none() => backup = Some(args[i + 1].clone()),
            other => bail!("Unknown or repeated init option: {other}"),
        }
        i += 2;
    }
    let backup = backup.ok_or_else(|| anyhow::anyhow!("Specify a backup directory."))?;
    let actual_backup = platform::path::resolve(Path::new(&backup), false, false)?;
    let config_path = platform::path::resolve(path, true, false)?;
    let data = ConfigData {
        allowed_roots: roots,
        backup_directory: actual_backup
            .to_str()
            .ok_or_else(|| anyhow::anyhow!("Backup directory must be valid Unicode."))?
            .into(),
        capacity_default_migration_version: 1,
        ..Default::default()
    };
    data.validate_fields()?;
    let config = Config {
        path: config_path.clone(),
        data,
    };
    crate::files::validate_config(&config)?;
    platform::write_new_plain_file(&config_path, &serde_json::to_vec(&config.data)?)?;
    write_json(
        &json!({"status":"initialized","configPath":config_path,"allowedRoots":config.data.allowed_roots,"backupDirectory":config.data.backup_directory}),
    )?;
    Ok(0)
}

fn read_paths(path: &str) -> Result<Vec<String>> {
    let bytes = platform::read_plain_file(Path::new(path), 1024 * 1024, true)?;
    let bytes = bytes.strip_prefix(b"\xef\xbb\xbf").unwrap_or(&bytes);
    let paths: Vec<String> = serde_json::from_slice(bytes)?;
    ensure!(
        (1..=256).contains(&paths.len()),
        "Paths file must contain between 1 and 256 path strings."
    );
    Ok(paths)
}

fn targets(args: &[String], offset: usize) -> Result<Vec<String>> {
    if args.len() == offset + 2 && args[offset] == "--paths-file" {
        read_paths(&args[offset + 1])
    } else if args.len() > offset + 1 && args[offset] == "--" {
        Ok(args[offset + 1..].to_vec())
    } else {
        bail!("Use -- <absolute-path> [...] or --paths-file <absolute-json-file>.");
    }
}

fn parse_command(command: &str, args: &[String]) -> Result<Value> {
    match command {
        "delete" => {
            let (mut dry_run, mut recursive, mut offset) = (false, false, 0);
            // 廃止済みの`--permanent-reserved-tree`は受理しない。他の未知optionと同じく
            // targets()の用法errorで拒否する。
            while offset < args.len()
                && matches!(args[offset].as_str(), "--dry-run" | "--recursive")
            {
                match args[offset].as_str() {
                    "--dry-run" if !dry_run => dry_run = true,
                    "--recursive" if !recursive => recursive = true,
                    _ => bail!("Repeated delete option: {}", args[offset]),
                };
                offset += 1;
            }
            Ok(json!({"paths":targets(args,offset)?,"dryRun":dry_run,"recursive":recursive}))
        }
        "delete-queue" => {
            let recursive = args.first().is_some_and(|a| a == "--recursive");
            Ok(
                json!({"paths":targets(args,usize::from(recursive))?,"recursive":recursive,"action":"enqueue"}),
            )
        }
        "delete-queue-status" | "delete-queue-cancel" => {
            ensure!(
                args.len() == 1 && !args[0].trim().is_empty(),
                "Use {command} <job-id>."
            );
            Ok(
                json!({"jobId":args[0],"action":if command=="delete-queue-status" {"status"} else {"cancel"}}),
            )
        }
        "__delete-queue-worker" => {
            #[cfg(windows)]
            ensure!(args.is_empty(), "Queue worker accepts no arguments.");
            #[cfg(target_os = "macos")]
            ensure!(args.len() <= 1, "Queue worker accepts one job id.");
            Ok(match args.first() {
                Some(id) => json!({"jobId":id}),
                None => json!({}),
            })
        }
        #[cfg(target_os = "macos")]
        "__delete-queue-contact" => {
            ensure!(
                args.len() == 2 && matches!(args[1].as_str(), "status" | "cancel" | "probe"),
                "Invalid macOS queue contact arguments."
            );
            Ok(json!({"jobId":args[0],"action":args[1]}))
        }
        "registry-delete" => parse_registry_delete(args),
        "restore" | "registry-restore" => {
            let (mut id, mut access) = (None, None);
            let mut i = 0;
            while i < args.len() {
                if args[i] == "--access-mode"
                    && access.is_none()
                    && i + 1 < args.len()
                    && matches!(args[i + 1].as_str(), "normal" | "backupRestore")
                {
                    access = Some(args[i + 1].clone());
                    i += 2;
                } else if !args[i].starts_with("--") && id.is_none() {
                    id = Some(args[i].clone());
                    i += 1;
                } else {
                    bail!(
                        "Use registry-restore <operation-id> [--access-mode <normal|backupRestore>]. Unknown or duplicate options are refused."
                    );
                }
            }
            Ok(
                json!({"operationId":id.ok_or_else(||anyhow::anyhow!("Registry restore requires an operation id."))?,"accessMode":access.unwrap_or_else(||"normal".into())}),
            )
        }
        "registry-reconcile" => {
            ensure!(
                args.len() == 1,
                "Registry reconciliation requires exactly one operation id."
            );
            Ok(json!({"operationId":args[0]}))
        }
        "registry-session" => {
            ensure!(
                args.len() == 3 && args[0] == "--minutes" && args[2] == "--assert-native-windows",
                "Use registry-session --minutes <1..60> --assert-native-windows from a normal Windows desktop."
            );
            Ok(json!({"minutes":args[1].parse::<u32>()?,"assertNativeWindows":true}))
        }
        "operations" => {
            ensure!(args.is_empty(), "Operations accepts no arguments.");
            Ok(json!({}))
        }
        "purge" => {
            ensure!(
                (1..=2).contains(&args.len())
                    && (args.len() == 1 || matches!(args[1].as_str(), "--dry-run" | "--apply")),
                "Use purge <operation-id> [--dry-run | --apply]."
            );
            Ok(json!({"operationId":args[0],"apply":args.len()==2 && args[1]=="--apply"}))
        }
        "maintain" => {
            flags(args, &["--dry-run", "--apply", "--audit-records"], 2)?;
            Ok(
                json!({"apply":args.iter().any(|x|x=="--apply"),"auditRecords":args.iter().any(|x|x=="--audit-records")}),
            )
        }
        "migrate" => {
            flags(
                args,
                &[
                    "--dry-run",
                    "--apply",
                    "--if-needed",
                    "--retry-legacy-discard",
                ],
                3,
            )?;
            let apply = args.iter().any(|x| x == "--apply");
            let if_needed = args.iter().any(|x| x == "--if-needed");
            let retry = args.iter().any(|x| x == "--retry-legacy-discard");
            ensure!(
                (!if_needed || apply) && (!retry || (apply && !if_needed)),
                "Use migrate [--dry-run | --apply [--if-needed | --retry-legacy-discard]]. Explicit retry acknowledgement cannot be combined with --if-needed."
            );
            Ok(json!({"apply":apply,"ifNeeded":if_needed,"retryLegacyDiscard":retry}))
        }
        "__begin-published-update" => {
            ensure!(
                (1..=2).contains(&args.len()),
                "Published update requires a release commit and optional expected installed commit."
            );
            Ok(json!({"argv":args}))
        }
        "__check-startup-budget" => {
            ensure!(
                args.len() == 1 && nonnegative_i64(&args[0]),
                "Specify the additional update storage bytes."
            );
            Ok(json!({"argv":args}))
        }
        "__download-published-package" => {
            ensure!(
                matches!(args.len(), 5 | 6)
                    && nonnegative_i64(&args[2])
                    && nonnegative_i64(&args[4]),
                "Published download requires repository, commit, asset ID, SHA-256, byte length and an optional release tag."
            );
            Ok(json!({"argv":args}))
        }
        "__prepare-published-package" => {
            ensure!(
                args.len() == 7 && nonnegative_i64(&args[5]) && nonnegative_i64(&args[6]),
                "Published preparation requires repository, branch, commit, runtime, SHA-256, byte length and asset ID."
            );
            Ok(json!({"argv":args}))
        }
        "__apply-startup-update"
        | "__apply-startup-integration"
        | "__confirm-startup-integration"
        | "__cleanup-startup-stage" => {
            ensure!(args.is_empty(), "Startup command accepts no arguments.");
            Ok(json!({"argv":args}))
        }
        _ => bail!("Unknown command: {command}"),
    }
}

// 更新用の数値は従来のInvariantCulture / NumberStyles.Noneと同じ範囲に固定する。
// Rustの符号なしparseが許す先頭の+や、Int64を超える値まで受け入れない。
fn nonnegative_i64(value: &str) -> bool {
    !value.is_empty() && value.bytes().all(|c| c.is_ascii_digit()) && value.parse::<i64>().is_ok()
}

fn flags(args: &[String], allowed: &[&str], max: usize) -> Result<()> {
    ensure!(
        args.len() <= max
            && args.iter().collect::<HashSet<_>>().len() == args.len()
            && args.iter().all(|a| allowed.contains(&a.as_str()))
            && !(args.iter().any(|x| x == "--dry-run") && args.iter().any(|x| x == "--apply")),
        "Unknown, duplicate, or incompatible options."
    );
    Ok(())
}

fn parse_registry_delete(args: &[String]) -> Result<Value> {
    let (mut view, mut value, mut access) = (None, None, None);
    let (mut recursive, mut dry_run, mut i) = (false, false, 0);
    while i < args.len() && args[i] != "--" {
        let option = &args[i];
        i += 1;
        match option.as_str() {
            "--view"
                if view.is_none() && i < args.len() && matches!(args[i].as_str(), "32" | "64") =>
            {
                view = Some(args[i].clone());
                i += 1;
            }
            "--access-mode"
                if access.is_none()
                    && i < args.len()
                    && matches!(args[i].as_str(), "normal" | "backupRestore") =>
            {
                access = Some(args[i].clone());
                i += 1;
            }
            "--value-name" if value.is_none() && i < args.len() && args[i] != "--" => {
                value = Some(args[i].clone());
                i += 1;
            }
            "--recursive" if !recursive => recursive = true,
            "--dry-run" if !dry_run => dry_run = true,
            _ if option.starts_with("--value-name=") && value.is_none() => {
                value = Some(option[13..].into())
            }
            _ => bail!("Unknown, duplicate, missing or invalid registry-delete option: {option}"),
        }
    }
    ensure!(
        view.is_some() && i < args.len() && args[i] == "--" && args.len() - i == 2,
        "Use registry-delete --view <32|64> [options] -- <single registry-key-path>."
    );
    ensure!(
        !(value.is_some() && recursive),
        "Recursive cannot be combined with value-name."
    );
    let mut result = json!({"path":args[i+1],"view":view.unwrap(),"recursive":recursive,"dryRun":dry_run,"accessMode":access.unwrap_or_else(||"normal".into())});
    if let Some(value) = value {
        result["valueName"] = Value::String(value);
    }
    Ok(result)
}

fn command_failed(command: &str, value: &Value) -> bool {
    if command == "mcp-cache-maintain" {
        return (value.get("dryRun") != Some(&Value::Bool(true))
            && value.get("cleanupBlocked") == Some(&Value::Bool(true)))
            || has_errors(value);
    }
    // 更新の途中phaseはlauncherが次段を実行するための正常応答。
    if command == "__apply-startup-update" {
        return matches!(
            value.get("status").and_then(Value::as_str),
            Some("deferred" | "ambiguous")
        );
    }
    if command == "migrate" {
        // 保全した旧領域のreason/complete=falseは失敗ではない。旧RecoveryMigrationResult契約を維持する。
        if crate::result_status::has_direct_error(value) {
            return true;
        }
        let Ok(result) = crate::migration::MigrationResult::deserialize(value) else {
            return true;
        };
        return (!result.dry_run && !result.registry_ready)
            || result
                .operations
                .iter()
                .any(|operation| matches!(operation.status.as_str(), "failed" | "ambiguous"));
    }
    has_errors(value)
}

// 公開名は既存の呼出し元との互換性のため保持する。
pub fn has_errors(value: &Value) -> bool {
    crate::result_status::has_operation_errors(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hook_start_failures_are_hook_denials() {
        // hook分岐より前の検査で失敗する入力。stdinを読む前に失敗するため、テスト中に入力を待たない。
        let relative: Vec<OsString> = ["--config", "relative.json", "hook"]
            .into_iter()
            .map(OsString::from)
            .collect();
        assert_eq!(run(relative, Host::Cli), 0);
        // 非Windowsではstartup::enterが配置状態を参照するため、単体テストではWindowsだけで確認する。
        #[cfg(windows)]
        let config = std::env::temp_dir().join("prunlet-hook-start-check.json");
        #[cfg(windows)]
        {
            let extra: Vec<OsString> = vec![
                "--config".into(),
                config.into_os_string(),
                "hook".into(),
                "--unexpected".into(),
            ];
            assert_eq!(run(extra, Host::Cli), 0);
        }
        // hook以外のcommandは従来どおりerror JSONとexit 1。
        let other: Vec<OsString> = ["--config", "relative.json", "validate-config"]
            .into_iter()
            .map(OsString::from)
            .collect();
        assert_eq!(run(other, Host::Cli), 1);
    }

    #[test]
    fn retired_delete_option_is_an_unknown_option() {
        let error = parse_command(
            "delete",
            &[
                "--permanent-reserved-tree".into(),
                "--".into(),
                r"C:\fixture".into(),
            ],
        )
        .unwrap_err()
        .to_string();
        assert!(error.starts_with("Use -- <absolute-path>"), "{error}");
        assert!(
            parse_command(
                "delete",
                &["--recursive".into(), "--".into(), r"C:\fixture".into()]
            )
            .is_ok()
        );
    }

    #[test]
    fn migrate_usage_matches_accepted_option_combinations() {
        let parse = |args: &[&str]| {
            parse_command(
                "migrate",
                &args.iter().map(|a| (*a).to_owned()).collect::<Vec<_>>(),
            )
        };
        for ok in [
            &[][..],
            &["--dry-run"],
            &["--apply"],
            &["--apply", "--if-needed"],
            &["--apply", "--retry-legacy-discard"],
        ] {
            assert!(parse(ok).is_ok(), "{ok:?}");
        }
        for bad in [
            &["--if-needed"][..],
            &["--retry-legacy-discard"],
            &["--dry-run", "--if-needed"],
            &["--apply", "--if-needed", "--retry-legacy-discard"],
        ] {
            assert!(parse(bad).is_err(), "{bad:?}");
        }
        #[cfg(windows)]
        assert!(
            HELP.contains("migrate [--dry-run | --apply [--if-needed | --retry-legacy-discard]]")
        );
    }

    #[test]
    fn mcp_cleanup_blocked_is_non_success_even_when_items_are_retained() {
        assert!(command_failed(
            "mcp-cache-maintain",
            &json!({"dryRun":false,"cleanupBlocked":true,"items":[{"status":"retained"}]})
        ));
        assert!(!command_failed(
            "mcp-cache-maintain",
            &json!({"dryRun":false,"cleanupBlocked":false,"status":"acknowledged","items":[]})
        ));
        assert!(!command_failed(
            "mcp-cache-maintain",
            &json!({"dryRun":true,"cleanupBlocked":true,"items":[{"status":"retained"}]})
        ));
        assert!(command_failed(
            "mcp-cache-maintain",
            &json!({"dryRun":true,"cleanupBlocked":true,"items":[{"status":"failed"}]})
        ));
    }

    #[test]
    fn startup_integration_phase_keeps_launcher_running() {
        let phase =
            json!({"status":"integration_required","phase":"switching","registryReady":false});
        assert!(!command_failed("__apply-startup-update", &phase));
        assert!(command_failed("migrate", &phase));
        for status in ["deferred", "ambiguous"] {
            assert!(command_failed(
                "__apply-startup-update",
                &json!({"status":status})
            ));
        }
    }

    fn migration_value(dry_run: bool, registry_ready: bool, complete: bool, status: &str) -> Value {
        serde_json::to_value(crate::migration::MigrationResult {
            dry_run,
            registry_ready,
            complete,
            operations: vec![crate::migration::MigrationOperation {
                status: status.into(),
                error: Some(
                    "Owned legacy state was safely retained for explicit inspection".into(),
                ),
                ..Default::default()
            }],
            warnings: vec!["The retained state remains unchanged".into()],
        })
        .unwrap()
    }

    #[test]
    fn migration_exit_keeps_retained_reasons_and_old_dry_run_policy() {
        for (dry, ready, complete, status, failed) in [
            (false, true, false, "retained", false),
            (false, true, true, "retained", false),
            (true, false, false, "retained", false),
            (true, true, false, "retained", false),
            (false, false, false, "retained", true),
            (false, true, false, "failed", true),
            (true, true, false, "failed", true),
            (false, true, false, "ambiguous", true),
            (true, false, false, "ambiguous", true),
            (false, true, false, "would_migrate", false),
        ] {
            let value = migration_value(dry, ready, complete, status);
            assert_eq!(command_failed("migrate", &value), failed, "{value}");
        }
        let retained = migration_value(false, true, false, "retained");
        assert!(command_failed("maintain", &retained));
        assert!(has_errors(&retained));
        let mut top_error = retained.clone();
        top_error["error"] = json!("Root actor failed before returning a migration result");
        assert!(command_failed("migrate", &top_error));
    }

    #[test]
    fn malformed_migration_results_remain_non_success() {
        assert!(command_failed("migrate", &Value::Null));
        assert!(command_failed("migrate", &json!({})));
        for (key, value) in [
            ("dryRun", json!("true")),
            ("registryReady", json!(1)),
            ("complete", json!("false")),
            ("operations", Value::Null),
            ("warnings", json!("not-an-array")),
        ] {
            let mut malformed = migration_value(true, true, false, "retained");
            malformed[key] = value;
            assert!(command_failed("migrate", &malformed), "{malformed}");
        }
        let mut malformed = migration_value(true, true, false, "retained");
        malformed["operations"][0]["status"] = json!(false);
        assert!(command_failed("migrate", &malformed));
    }
}

#[cfg(target_os = "linux")]
const HELP: &str = r#"Prunlet — Linux freedesktop Trash.
prunlet --config <absolute-json-path> init --backup-directory <directory>
prunlet --config <absolute-json-path> validate-config
prunlet --config <absolute-json-path> delete [--dry-run] [--recursive] -- <absolute-path> [...]
prunlet --config <absolute-json-path> delete [--dry-run] [--recursive] --paths-file <absolute-json-file>
prunlet --config <absolute-json-path> mcp
prunlet --config <absolute-json-path> hook
"#;
#[cfg(target_os = "macos")]
const HELP: &str = r#"Prunlet — Apple Silicon macOS Trash.
prunlet --install-macos <new absolute installation path>
prunlet --config <absolute-json-path> init --backup-directory <directory>
prunlet --config <absolute-json-path> validate-config
prunlet --config <absolute-json-path> delete [--dry-run] [--recursive] -- <absolute-path> [...]
prunlet --config <absolute-json-path> delete [--dry-run] [--recursive] --paths-file <absolute-json-file>
prunlet --config <absolute-json-path> delete-queue [--recursive] -- <absolute-path> [...]
prunlet --config <absolute-json-path> delete-queue-status <job-id>
prunlet --config <absolute-json-path> delete-queue-cancel <job-id>
prunlet --config <absolute-json-path> mcp
prunlet --config <absolute-json-path> hook
"#;
#[cfg(windows)]
const HELP: &str = r#"Prunlet — Windows Recycle Bin deletion and registry recovery.
prunlet --config <absolute-json-path> init --backup-directory <directory>
prunlet --config <absolute-json-path> validate-config
prunlet --config <absolute-json-path> delete [--dry-run] [--recursive] -- <absolute-path> [...]
prunlet --config <absolute-json-path> delete [--dry-run] [--recursive] --paths-file <absolute-json-file>
prunlet --config <absolute-json-path> delete-queue [--recursive] -- <absolute-path> [...]
prunlet --config <absolute-json-path> delete-queue [--recursive] --paths-file <absolute-json-file>
prunlet --config <absolute-json-path> delete-queue-status <job-id>
prunlet --config <absolute-json-path> delete-queue-cancel <job-id>
prunlet --config <absolute-json-path> registry-delete --view <32|64> [--access-mode <normal|backupRestore>] [--value-name <literal-name> | --value-name=] [--recursive] [--dry-run] -- <registry-key-path>
prunlet --config <absolute-json-path> registry-session --minutes <1..60> --assert-native-windows
prunlet --config <absolute-json-path> registry-reconcile <operation-id>
prunlet --config <absolute-json-path> registry-restore <operation-id> [--access-mode <normal|backupRestore>]
prunlet --config <absolute-json-path> restore <registry-operation-id> [--access-mode <normal|backupRestore>]
prunlet --config <absolute-json-path> purge <operation-id> [--dry-run | --apply]
prunlet --config <absolute-json-path> maintain [--dry-run | --apply] [--audit-records]
prunlet --config <absolute-json-path> operations
prunlet --config <absolute-json-path> migrate [--dry-run | --apply [--if-needed | --retry-legacy-discard]]
prunlet --config <absolute-json-path> mcp
prunlet --config <absolute-json-path> hook [--hook-script <legacy-path>]
Legacy --allowed-root <directory> options are accepted but do not restrict target directories.
Metadata and volume recovery directories are protected.
Files and folders normally move into the Windows Recycle Bin without Prunlet operation records.
An ordinary file with a Windows reserved final name is permanently deleted after identity checks, without using the bin.
Dry-run reports that case as would_permanently_delete. Reserved-name directories and links are rejected.
When Windows reports a file or folder too large for the bin, Prunlet attempts to permanently delete its confirmed original.
Only a confirmed removal returns permanently_deleted; an uncertain attempt returns ambiguous.
Other recycling failures do not trigger permanent deletion. Dry-run cannot predict an ordinary item's bin-size outcome.
Restore recycled items using Windows Recycle Bin; permanently deleted items cannot be restored there.
Registry snapshots retain the configured 7-day / 1 GiB defaults.
Maintain and purge manage registry recovery only; inspection is the default.
Migrate discards owned legacy file recovery data through Windows Recycle Bin; registry recovery stays protected.
After checking an interrupted discard, use migrate --apply --retry-legacy-discard to explicitly acknowledge retry.
Restore and registry-restore accept registry operation IDs and never overwrite existing keys or values.
Recycled hard links share content with surviving aliases.
For ambiguous file results, inspect the source and Windows Recycle Bin; do not resend deletion.
Empty directories are supported; deleting directory contents requires --recursive.
Wildcard expansion is unsupported. Links are deleted without following their targets.
Registry view is required. Omit value-name for a key; an empty value-name selects the default value.
Registry access defaults to normal. backupRestore is explicit per deletion/restoration, requires effective-token privileges, and supports only view 64 in a 64-bit Windows process.
Registry key snapshots require full Owner/Group/DACL/SACL access and SeSecurityPrivilege; no automatic elevation or fallback."#;
