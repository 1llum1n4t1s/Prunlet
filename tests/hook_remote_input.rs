#![cfg(windows)]
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use std::{
    io::Write,
    process::{Command, Stdio},
};
// 2026-11-04T05:33:48.296Zの拒否出力の最後のCommand:から取得。本文はhookのJSON dataだけに渡す。
const HISTORICAL: &str = r####"@'
import {spawnSync} from 'node:child_process';
const root='/tmp/kg-grok-linux-20261104.X57oHVlC';
const q=s=>"'"+s.replaceAll("'","'\\''")+"'";
const script=`set -e
root=${root}
test "$root" = "$(realpath -- "$root")"
test -d "$root" && test ! -L "$root"
/home/szk.guest/.volta/tools/image/node/22.0.0/bin/node --input-type=module - "$root" <<'NODE'
import fs from 'node:fs';
import path from 'node:path';
const root=process.argv[2];
if(fs.realpathSync(root)!==root || !/^\\/tmp\\/kg-grok-linux-20261104\\.[A-Za-z0-9]+$/.test(root)) throw Error('Unexpected cleanup root');
let files=0;
function walk(dir) {for(const item of fs.readdirSync(dir,{withFileTypes:true})){const p=path.join(dir,item.name); if(item.isSymbolicLink()) throw Error('Link requires review: '+p); if(item.isDirectory())walk(p); else files++;}}
walk(root);
const held=[];let scanned=0;
for(const pid of fs.readdirSync('/proc').filter(s=>/^\\d+$/.test(s))){
const proc='/proc/'+pid;let owner;try{owner=fs.statSync(proc).uid;}catch(e){if(e.code==='ENOENT')continue;throw e;}
if(owner!==process.getuid())continue;
scanned++;
let refs=[proc+'/cwd',proc+'/exe'];
try{refs.push(...fs.readdirSync(proc+'/fd').map(fd=>proc+'/fd/'+fd));}catch(e){if(e.code==='ENOENT')continue;throw e;}
for(const ref of refs){let target;try{target=fs.readlinkSync(ref);}catch(e){if(['ENOENT','EINVAL'].includes(e.code))continue;throw e;}
if(target===root || target.startsWith(root+'/'))held.push({pid,ref,target});}
}
if(held.length)throw Error('Cleanup root is held: '+JSON.stringify(held));
console.log('Cleanup verified: '+files+' files; no filesystem links; '+scanned+' current-user processes checked, no holders. Other UIDs are outside inspection scope.');
NODE
rm -rf -- "$root"
test ! -e "$root"
printf 'Removed and verified absent: %s\\n' "$root"
`;
const result=spawnSync('C:/Program Files/Git/usr/bin/ssh.exe',['mac','/opt/homebrew/bin/limactl shell --start linux-validation -- bash -c '+q(script)],{stdio:'inherit'});
if(result.error)throw result.error;
process.exitCode=result.status??1;
'@ | node --input-type=module"####;

fn inspect_raw(input: &str) -> Value {
    let executable =
        std::env::var_os("PRUNLET_HOOK_EXE").expect("PRUNLET_HOOK_EXE must bind the candidate CLI");
    let config = std::path::PathBuf::from(&executable).with_file_name("hook-test-config.json");
    assert!(config.is_absolute());
    let mut child = Command::new(executable)
        .arg("--config")
        .arg(config)
        .arg("hook")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(input.as_bytes())
        .unwrap();
    let result = child.wait_with_output().unwrap();
    assert!(
        result.status.success(),
        "hook process failed: status={:?}, stdout={:?}, stderr={:?}",
        result.status,
        result.stdout,
        result.stderr
    );
    serde_json::from_slice(&result.stdout).unwrap()
}
fn inspect(input: &Value) -> Value {
    inspect_raw(&serde_json::to_string(input).unwrap())
}
fn request(command: &str) -> Value {
    json!({"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":command,"workdir":"D:\\Dev\\Prunlet","yield_time_ms":1000,"max_output_tokens":1400,"login":false,"opaque":{"keep":[1,null,true]}}})
}
fn decision(output: &Value) -> Option<&str> {
    output["hookSpecificOutput"]["permissionDecision"].as_str()
}
fn canonical(script: &str) -> String {
    let script = format!("# Prunlet\n{script}");
    let bytes: Vec<_> = script.encode_utf16().flat_map(u16::to_le_bytes).collect();
    let encoded = STANDARD.encode(bytes);
    let decoded = STANDARD.decode(&encoded).unwrap();
    let units: Vec<_> = decoded
        .chunks_exact(2)
        .map(|p| u16::from_le_bytes([p[0], p[1]]))
        .collect();
    assert_eq!(String::from_utf16(&units).unwrap(), script);
    format!("pwsh -NoProfile -EncodedCommand {encoded}")
}
fn prepared_request(input: &Value) -> Value {
    let original = input.clone();
    let mut prepared = input.clone();
    prepared["tool_input"]["command"] =
        json!(canonical(input["tool_input"]["command"].as_str().unwrap()));
    let mut preserved = prepared["tool_input"].clone();
    preserved["command"] = input["tool_input"]["command"].clone();
    assert_eq!(preserved, input["tool_input"], "producer changed metadata");
    assert_eq!(*input, original, "producer changed its source");
    prepared
}
#[test]
#[ignore = "Requires PRUNLET_HOOK_EXE bound to the installed CLI; command fixtures are never executed"]
fn historical_raw_denied_and_shell_before_encoding_passes() {
    assert!(HISTORICAL.contains("rm -rf --"));
    for source in [HISTORICAL.to_owned(), HISTORICAL.replace('\n', "\r\n")] {
        let input = request(&source);
        assert_eq!(decision(&inspect(&input)), Some("deny"));
        let prepared = prepared_request(&input);
        assert!(prepared["tool_input"]["command"].as_str().unwrap().len() <= 8000);
        assert_eq!(inspect(&prepared), json!({}));
        assert_eq!(
            inspect(&prepared),
            json!({}),
            "canonical inspection is stable"
        );
    }
}
#[test]
#[ignore = "Requires PRUNLET_HOOK_EXE bound to the installed CLI; command fixtures are never executed"]
fn utf16_producer_preserves_literals_and_non_ascii_data() {
    for data in [
        "// & del /q D:\\victim & rem",
        "//'; rm -rf -- /tmp/victim; : '",
        "// 日本語と🌱をそのまま保持",
    ] {
        let input = request(&format!("@'\n{data}\n'@ | node --input-type=module"));
        assert_eq!(inspect(&prepared_request(&input)), json!({}));
    }
}
#[test]
#[ignore = "Requires PRUNLET_HOOK_EXE bound to the installed CLI; command fixtures are never executed"]
fn encoded_local_deletions_and_unsupported_invocations_remain_denied() {
    for script in [
        "Remove-Item -LiteralPath D:\\PrunletHookNeverExecute".to_owned(),
        format!("Remove-Item D:\\PrunletHookNeverExecute\n{HISTORICAL}"),
        format!("{HISTORICAL}\nRemove-Item D:\\PrunletHookNeverExecute"),
        "cmd /c \"del D:\\PrunletHookNeverExecute\"".to_owned(),
        "reg delete HKCU\\Software\\PrunletHookNeverExecute /f".to_owned(),
    ] {
        assert_eq!(
            decision(&inspect(&request(&canonical(&script)))),
            Some("deny")
        );
    }
    for command in [
        "pwsh -NoProfile -EncodedCommand !!!",
        "pwsh -NoProfile -EncodedCommand QQ==",
        "pwsh -NoProfile -EncodedCommand AA==; del D:\\PrunletHookNeverExecute",
        "Remove-Item D:\\PrunletHookNeverExecute",
    ] {
        assert_eq!(decision(&inspect(&request(command))), Some("deny"));
    }
}
#[test]
#[ignore = "Requires PRUNLET_HOOK_EXE bound to the installed CLI; command fixtures are never executed"]
fn explicit_shell_and_metadata_keep_existing_behavior() {
    let mut input = request(HISTORICAL);
    input["tool_name"] = json!("exec_command");
    input["tool_input"]["shell"] = json!("pwsh");
    assert_eq!(inspect(&input), json!({}));
    for name in ["exec_command", "functions.exec_command"] {
        let mut raw = request(HISTORICAL);
        raw["tool_name"] = json!(name);
        assert_eq!(decision(&inspect(&raw)), Some("deny"));
        let prepared = prepared_request(&raw);
        assert_eq!(inspect(&prepared), json!({}));
    }
    assert_eq!(inspect(&request("echo safe")), json!({}));
}

#[test]
#[ignore = "Requires PRUNLET_HOOK_EXE bound to the candidate CLI; command fixtures are never executed"]
fn existing_json_and_explicit_shell_boundaries_are_preserved() {
    let cases: Vec<Value> =
        serde_json::from_str(include_str!("../src/rust/protocol/tests/hook-posix.json")).unwrap();
    let mut checked = 0;
    for case in cases {
        for tool in ["Bash", "exec_command", "functions.exec_command"] {
            let command = case["command"]
                .as_str()
                .unwrap()
                .replace("<FILE>", r"D:\PrunletHookNeverExecute");
            let mut arguments = json!({});
            arguments[if tool == "Bash" { "command" } else { "cmd" }] = json!(command);
            if tool != "Bash" {
                arguments["shell"] = json!("/bin/sh");
            }
            let response = inspect(&json!({"tool_name":tool,"tool_input":arguments}));
            let expected = case
                .get("windowsPass")
                .unwrap_or(&case["pass"])
                .as_bool()
                .unwrap();
            assert_eq!(
                response == json!({}),
                expected,
                "{} / {tool}: {response}",
                case["name"]
            );
            if !expected {
                assert_eq!(decision(&response), Some("deny"));
                let reason = response["hookSpecificOutput"]["permissionDecisionReason"]
                    .as_str()
                    .unwrap();
                assert!(reason.contains("interpretation=") || reason.contains("could not inspect"));
            }
            checked += 1;
        }
    }
    for (command, shell, pass) in [
        ("# safe & del D:\\PrunletHookNeverExecute", "cmd.exe", false),
        ("if \"del\" == \"del\" echo safe", "cmd.exe", true),
        (
            "if \"a==b\" == \"a==b\" del D:\\PrunletHookNeverExecute",
            "cmd.exe",
            false,
        ),
        (
            "reg delete HKCU\\Software\\PrunletHookNeverExecute /f",
            "pwsh",
            false,
        ),
        (
            "Remove-ItemProperty HKCU:\\Software\\PrunletHookNeverExecute -Name value",
            "pwsh",
            false,
        ),
        ("rg -n 'item|rmdir|tail' sample.txt", "pwsh", true),
    ] {
        let response = inspect(
            &json!({"hook_event_name":"PreToolUse","tool_name":"exec_command","tool_input":{"cmd":command,"shell":shell}}),
        );
        assert_eq!(response == json!({}), pass, "{command}: {response}");
        if !pass {
            assert_eq!(decision(&response), Some("deny"));
        }
        checked += 1;
    }
    println!("Existing JSON and selected explicit-shell boundaries checked: {checked}");
}
