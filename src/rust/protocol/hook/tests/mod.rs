use super::*;

mod cmd;
mod inspection;
mod posix;
mod posix_json;
mod powershell;
mod regression;

/// PowerShellスクリプトをUTF-16LEのBase64へ変換する（-EncodedCommandの引数形式）。
fn encode_utf16_base64(script: &str) -> String {
    let bytes: Vec<u8> = script.encode_utf16().flat_map(u16::to_le_bytes).collect();
    STANDARD.encode(bytes)
}
/// `pwsh -NoProfile -EncodedCommand <base64>` の完全なコマンド文字列を作る。
fn encoded_command(script: &str) -> String {
    format!(
        "pwsh -NoProfile -EncodedCommand {}",
        encode_utf16_base64(script)
    )
}
/// hook入力を組み立ててinspectへ渡し、拒否なら理由を返す。検査errorもrun()と同じく拒否として扱う。
/// 文字列はhookへ渡すだけで実行しない。
fn reason(command: &str, tool: &str, shell: Option<&str>) -> Option<String> {
    let mut tool_input = json!({ "command": command });
    if let Some(shell) = shell {
        tool_input["shell"] = json!(shell);
    }
    let input = json!({ "tool_name": tool, "tool_input": tool_input });
    match inspect(
        &input,
        Path::new(r"C:\fixture\config.json"),
        Path::new(r"C:\fixture\prunlet.exe"),
    ) {
        Ok(value) if value == json!({}) => None,
        Ok(value) => Some(
            value["hookSpecificOutput"]["permissionDecisionReason"]
                .as_str()
                .unwrap_or_default()
                .to_owned(),
        ),
        Err(error) => Some(format!("Prunlet could not inspect the hook input: {error}")),
    }
}
fn denied(command: &str, shell: &str) -> bool {
    reason(command, "exec_command", Some(shell)).is_some()
}
// 正規のPrunlet CLI呼出し。`/d /c`とMSYS向けの`//d //c`、call付きの各形を通過させる。
const CANONICAL_CLI: [&str; 4] = [
    r#"cmd.exe /d /c "C:\Users\me\.local\Prunlet\bin\prunlet.exe --config C:\Users\me\.local\Prunlet\config.json delete --paths-file D:\work\paths.json""#,
    r#"cmd.exe //d //c "C:\Users\me\.local\Prunlet\bin\prunlet.exe --config C:\Users\me\.local\Prunlet\config.json delete --paths-file D:\work\paths.json""#,
    r#"cmd.exe /d /c call "C:\Users\me\.local\Prunlet\bin\prunlet.exe" --config "C:\Users\me\.local\Prunlet\config.json" delete --paths-file "D:\work\paths.json""#,
    r#"cmd.exe //d //c call "C:\Users\me\.local\Prunlet\bin\prunlet.exe" --config "C:\Users\me\.local\Prunlet\config.json" delete --paths-file "D:\work\paths.json""#,
];
/// POSIX規則だけで検査した結果（Windowsの候補解釈がPOSIX固有の穴を覆い隠さないようにする）。
fn posix_denied(command: &str) -> bool {
    let result = Inspector::default().contains(command, 0, Some(Mode::Posix), false);
    result.is_err() || result.unwrap()
}
const JS_BODY: &str = "for (const f of files) {\n  if (f) { rm(f) }\n}\nrm -rf /tmp/y\ndel x\nri y";
/// 1つの読みの系統（`reading`）だけで、POSIX規則として検査した結果。
fn posix_reading_denied(command: &str, legacy: bool) -> bool {
    let mut inspector = Inspector {
        reading: Some(legacy),
        ..Inspector::default()
    };
    let result = inspector.contains(command, 0, Some(Mode::Posix), false);
    result.is_err() || result.unwrap()
}
