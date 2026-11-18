use super::bounded_input::read_to_end;
use anyhow::{Result, bail};
use base64::{Engine, engine::general_purpose::STANDARD};
use regex::Regex;
use serde_json::{Value, json};
use std::{borrow::Cow, io, path::Path, sync::LazyLock};

mod heredoc;
mod inspector;
mod lexer;
mod names;
mod shell_helpers;
mod sinks;
mod subexpr;
#[cfg(test)]
mod tests;
mod token;
mod words;

use heredoc::*;
use inspector::Inspector;
use lexer::*;
use names::*;
use shell_helpers::*;
use sinks::*;
use subexpr::*;
use token::*;
use words::*;

fn inspect(input: &Value, config: &Path, cli: &Path) -> Result<Value> {
    if !input.is_object() {
        bail!("Hook input must be an object.");
    }
    let name = input
        .get("tool_name")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow::anyhow!("Hook tool_name must be a string."))?;
    if !matches!(name, "Bash" | "exec_command" | "functions.exec_command") {
        return Ok(json!({}));
    }
    let arguments = input
        .get("tool_input")
        .filter(|v| v.is_object())
        .ok_or_else(|| anyhow::anyhow!("Hook tool_input must be an object."))?;
    // `command`と`cmd`が併存する場合、どちらをホストが実行するかはここで決められないため、
    // 存在する全てを検査する（どれかが拒否対象なら拒否）。片方だけの入力の挙動は従来どおり。
    let mut commands = Vec::new();
    for key in ["command", "cmd"] {
        if let Some(value) = arguments.get(key) {
            commands.push(
                value
                    .as_str()
                    .ok_or_else(|| anyhow::anyhow!("Hook command must be a string."))?,
            );
        }
    }
    if commands.is_empty() {
        bail!("Hook command must be a string.");
    }
    let mode = if name != "Bash" {
        arguments
            .get("shell")
            .and_then(Value::as_str)
            .and_then(|s| shell(&leaf(s)))
    } else {
        None
    };
    let mut detected = None;
    for command in commands {
        let mut inspection = Inspector {
            admin_cli: cli.to_string_lossy().into_owned(),
            admin_config: config.to_string_lossy().into_owned(),
            ..Inspector::default()
        };
        if inspection.contains(command, 0, mode, false)? {
            detected = Some(inspection);
            break;
        }
    }
    let Some(inspection) = detected else {
        return Ok(json!({}));
    };
    // 単独EncodedCommandは復号本文をPowerShellとして確定検査しているため、
    // shell不明時の候補注記とEncodedCommandへの変換案内を付けない。
    let standalone_encoded = inspection.standalone_encoded;
    let deletion = inspection.deletion;
    let mut reason = inspection.detection.unwrap_or_else(|| {
        "Prunlet rejected this command because an invocation could not be safely classified.".into()
    });
    let executable = cli.to_string_lossy();
    let config = config.to_string_lossy();
    // 削除命令を検知していない拒否（構文を静的に検査できない場合）は、削除の手順を長く添えても
    // 役に立たず、拒否のたびに大量の文脈を消費する。原因と書き換えの方向だけを短く返す。
    if !deletion {
        if mode.is_none() && cfg!(windows) && !standalone_encoded {
            reason.push_str(" Shell metadata is missing or unsupported; this is a candidate interpretation, not a confirmed local deletion.");
        }
        reason.push_str(&format!(
            " The hook did not execute the command. This is an inspection limit, not a detected deletion: rewrite the command without that construct (for example, run the logic from a script file). For authorized deletions use the installed Prunlet CLI: {} --config {} delete --paths-file <absolute-json-file>.",
            cli_quote(&executable),
            cli_quote(&config)
        ));
        reason.push_str(setup_hint(cli));
        return Ok(deny(&reason));
    }
    if mode.is_none() && cfg!(windows) && !standalone_encoded {
        reason.push_str(" Shell metadata is missing or unsupported; this is a candidate interpretation, not a confirmed local deletion. Quoted search text or remote script data may be interpreted as command syntax. If the host forwards the tool as Bash without shell metadata, setting exec_command.shell alone cannot resolve this ambiguity. For an authorized SSH script sent from PowerShell, encode the entire local PowerShell script as UTF-16LE Base64 and submit the standalone form pwsh -NoProfile -EncodedCommand <base64>. The hook decodes and inspects that script; it does not exempt SSH names or remote deletion targets from inspection. See docs/integration.md for the supported form.");
    }
    if cfg!(windows) {
        reason.push_str(&format!(" The hook did not execute the command. The following CLI guidance applies only to authorized Windows deletion targets. For explicitly authorized targets, use the installed Prunlet CLI from the start with shell=cmd.exe and login=false: {} --config {} delete --paths-file <absolute-json-file>; for registry keys/values use {} --config {} registry-delete --view <32|64> [--value-name <literal-name> | --value-name=] [--recursive] -- <registry-key-path>. File and folder deletions have no Prunlet operation record. Normally restore recycled items using Windows Recycle Bin; a file or folder Windows reports as too large may instead be permanently deleted. Dry-run cannot predict the final disposition. Keep registry operationId and use registry-restore <operationId>. On hosts supporting exec_command sandbox permissions, request sandbox_permissions=\"require_escalated\" from the first real file deletion because Recycle Bin access may be restricted. This is a formal host permission request, not Windows UAC or administrator elevation. A dry-run does not prove real-operation permissions. Existing host approvals and policies still apply. Do not retry a policy-rejected target through another route or automatically resend a failed deletion; check uncertain file results using the source and Windows Recycle Bin; reconcile registry results using registry-reconcile <operationId> before deciding next steps.",cli_quote(&executable),cli_quote(&config),cli_quote(&executable),cli_quote(&config)));
    } else if cfg!(target_os = "linux") {
        reason.push_str(&format!(" The hook did not execute the command. For explicitly authorized local Linux targets use the installed Prunlet CLI: {} --config {} delete --paths-file <absolute-json-file>. Items move to the freedesktop home Trash on the same mount. Existing host approvals and policies still apply. Do not resend ambiguous deletion; inspect the source and Trash.", cli_quote(&executable), cli_quote(&config)));
    } else {
        reason.push_str(&format!(" The hook did not execute the command. For explicitly authorized local macOS targets use the installed native Prunlet CLI: {} --config {} delete --paths-file <absolute-json-file>. Files normally go to macOS Trash without Prunlet operation records. On macOS, delete-queue waits only for cooperating processes that hold an advisory flock; merely opening a file or mapping a dylib does not delay deletion. Registry operations are Windows-only and are unsupported on macOS. SSH names and remote script text do not bypass inspection. Existing host approvals and policies still apply. Do not resend failed or ambiguous deletion; inspect the source and Trash.",cli_quote(&executable),cli_quote(&config)));
    }
    reason.push_str(setup_hint(cli));
    Ok(deny(&reason))
}
/// 案内したCLIが実在しないWindowsの導入（Setup版を更新中・アンインストール後など）にだけ、再実行の案内を足す。
/// CLIが存在する通常の導入では空で、従来の拒否理由を1バイトも変えない。
fn setup_hint(cli: &Path) -> &'static str {
    if cfg!(windows) && !cli.exists() {
        " If that CLI is missing: retry in a minute (it may be mid-update), then rerun Setup."
    } else {
        ""
    }
}
/// 拒否理由へ添えるCLIパスの引用規則。各OSの完全な案内と同じ規則にそろえる。
/// Windowsは空白を含むときだけ二重引用し、他OSは常にPOSIXの単一引用にする。
fn cli_quote(s: &str) -> String {
    if !cfg!(windows) {
        format!("'{}'", s.replace('\'', "'\\''"))
    } else if s.chars().any(char::is_whitespace) {
        format!("\"{s}\"")
    } else {
        s.into()
    }
}
fn deny(reason: &str) -> Value {
    json!({"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":reason}})
}
pub fn run(config_path: &Path, cli_path: &Path) -> i32 {
    let result = (|| -> Result<Value> {
        let text = read_to_end(io::stdin().lock())?;
        let input: Value = serde_json::from_str(&text)?;
        inspect(&input, config_path, cli_path)
    })();
    let output = match result {
        Ok(v) => v,
        Err(e) => {
            eprintln!("Prunlet hook: {e}");
            deny(&format!("Prunlet could not inspect the hook input: {e}"))
        }
    };
    println!("{output}");
    0
}
