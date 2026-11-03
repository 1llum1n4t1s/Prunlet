"""実行しないhook JSONだけをCLIへ渡し、外部fixtureの不変更も検証する。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("--executable", required=True, type=Path)
parser.add_argument("--output-directory", required=True, type=Path)
parser.add_argument("--config", required=True, type=Path)
options = parser.parse_args()
for path in (options.executable, options.output_directory, options.config):
    if not path.is_absolute():
        raise SystemExit("Absolute paths are required")
for path in (options.output_directory, *options.output_directory.parents):
    if path.is_symlink():
        raise SystemExit("Output must not pass through a link")
options.output_directory.mkdir(exist_ok=False)
sentinel = options.output_directory / "hook-sentinel.txt"
sentinel.write_bytes(b"Hook fixture commands must never execute")
digest = hashlib.sha256(sentinel.read_bytes()).hexdigest()
cases = json.loads(Path(__file__).with_name("hook-posix.json").read_text(encoding="utf-8"))
results = []
for case in cases:
    for tool in ("Bash", "exec_command", "functions.exec_command"):
        args = {"command" if tool == "Bash" else "cmd": case["command"].replace("<FILE>", str(sentinel))}
        if tool != "Bash":
            args["shell"] = "/bin/sh"
        event = {"tool_name": tool, "tool_input": args}
        process = subprocess.run([str(options.executable), "--config", str(options.config), "hook"],
                                 input=json.dumps(event), text=True, capture_output=True, timeout=30)
        expected = case.get("windowsPass", case["pass"]) if os.name == "nt" else case["pass"]
        try:
            response = json.loads(process.stdout)
            decision = "pass" if response == {} else response["hookSpecificOutput"]["permissionDecision"]
            reason = response.get("hookSpecificOutput", {}).get("permissionDecisionReason", "")
            reason_valid = decision == "pass" or ("interpretation=" in reason or "could not inspect" in reason)
        except (ValueError, KeyError):
            decision, reason, reason_valid = "invalid", "", False
        unchanged = sentinel.exists() and hashlib.sha256(sentinel.read_bytes()).hexdigest() == digest
        passed = process.returncode == 0 and unchanged and reason_valid and decision == ("pass" if expected else "deny")
        results.append({"name": case["name"], "tool": tool, "input": event, "expectedPass": expected,
                        "decision": decision, "reason": reason, "fixtureUnchanged": unchanged,
                        "exitCode": process.returncode, "stderr": process.stderr, "passed": passed})
failed = [result for result in results if not result["passed"]]
report = {"executable": str(options.executable), "sha256": hashlib.sha256(options.executable.read_bytes()).hexdigest(),
          "passed": len(results) - len(failed), "failed": len(failed), "results": results}
(options.output_directory / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
print(f"passed={report['passed']} failed={report['failed']}")
for result in failed:
    print(f"FAIL {result['name']} {result['tool']}: {result['decision']}")
raise SystemExit(bool(failed))
