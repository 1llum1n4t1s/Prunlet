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

pub fn run(args: Vec<OsString>, mut host: Host) -> i32 {
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
            let value = json!({"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Prunlet hook could not start: Invalid Prunlet hook arguments."}});
            let _ = write_json(&value);
            return 0;
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
    if args == ["--startup-update-protocol"] {
        let protocol = if cfg!(windows) {
            json!({"protocol":1,"storageEpoch":1,"distributionSources":["github","r2"]})
        } else {
            json!({"protocol":1,"storageEpoch":1})
        };
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
    if command == "hook" {
        ensure!(
            tail.is_empty() || (tail.len() == 2 && tail[0] == "--hook-script"),
            "Use hook with no arguments, or legacy --hook-script <path>."
        );
        let executable = std::env::current_exe()?;
        return Ok(crate::protocol::hook::run(&config_path, &executable));
    }
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
    let runtime = Arc::new(Runtime::new(config));
    if command == "mcp" {
        ensure!(tail.is_empty(), "MCP accepts no arguments.");
        crate::protocol::mcp::run(runtime)?;
        return Ok(0);
    }
    let params = parse_command(command, tail)?;
    #[cfg(target_os = "macos")]
    if command == "delete-queue" {
        eprintln!(
            "[prunlet] macOS queue waits for cooperative advisory flock locks; ordinary open files and mapped libraries are not a wait condition."
        );
    }
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
            Ok(if let Some(id) = args.first() {
                json!({"jobId":id})
            } else {
                json!({})
            })
        }
        "__delete-queue-contact" => {
            ensure!(
                cfg!(target_os = "macos")
                    && args.len() == 2
                    && matches!(args[1].as_str(), "status" | "cancel" | "probe"),
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
                "Use migrate [--dry-run | --apply]. Explicit retry acknowledgement cannot be combined with --if-needed."
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
                args.len() == 1 && args[0].parse::<u64>().is_ok(),
                "Specify the additional update storage bytes."
            );
            Ok(json!({"argv":args}))
        }
        "__download-published-package" => {
            ensure!(
                matches!(args.len(), 5 | 7)
                    && args[2].parse::<u64>().is_ok()
                    && args[4].parse::<u64>().is_ok(),
                "Published download requires repository, commit, asset ID, SHA-256 and byte length."
            );
            Ok(json!({"argv":args}))
        }
        "__prepare-published-package" => {
            ensure!(
                matches!(args.len(), 7 | 8)
                    && args[5].parse::<u64>().is_ok()
                    && args[6].parse::<u64>().is_ok(),
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

const HELP: &str = "Prunlet — native Windows/macOS file deletion and Windows registry recovery.\nprunlet --config <absolute-json-path> init --backup-directory <directory>\nprunlet --config <absolute-json-path> validate-config\nprunlet --config <absolute-json-path> delete [--dry-run] [--recursive] --paths-file <absolute-json-file>\nprunlet --config <absolute-json-path> delete [--dry-run] [--recursive] -- <absolute-path> [...]\nprunlet --config <absolute-json-path> delete-queue [--recursive] --paths-file <absolute-json-file>\nprunlet --config <absolute-json-path> delete-queue-status <job-id>\nprunlet --config <absolute-json-path> delete-queue-cancel <job-id>\nprunlet --config <absolute-json-path> registry-delete --view <32|64> [--access-mode <normal|backupRestore>] [--value-name=<name>] [--recursive] [--dry-run] -- <registry-key-path>\nprunlet --config <absolute-json-path> registry-restore <operation-id> [--access-mode <normal|backupRestore>]\nprunlet --config <absolute-json-path> registry-reconcile <operation-id>\nprunlet --config <absolute-json-path> registry-session --minutes <1..60> --assert-native-windows\nprunlet --config <absolute-json-path> operations\nprunlet --config <absolute-json-path> maintain [--dry-run|--apply] [--audit-records]\nprunlet --config <absolute-json-path> purge <operation-id> [--dry-run|--apply]\nprunlet --config <absolute-json-path> migrate [--dry-run|--apply]\nprunlet --config <absolute-json-path> mcp\nprunlet --config <absolute-json-path> hook\nFile deletion creates no recovery record. Uncertain results are not retried. Registry operations are Windows-only.\n";
