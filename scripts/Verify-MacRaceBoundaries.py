#!/usr/bin/env python3
"""専用cfgビルドの停止点を使い、macOS削除境界の実プロセス競合を検証する。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import signal
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--executable", required=True, type=Path)
    parser.add_argument("--output-directory", required=True, type=Path)
    parser.add_argument("--source-root", required=True, type=Path)
    options = parser.parse_args()
    commands = []
    original_run, original_popen = subprocess.run, subprocess.Popen
    def record_command(argv,kwargs):
        argv=list(map(str,argv));record={'argv':argv,'inputFilesSha256':{}}
        for index,part in enumerate(argv[:-1]):
            if part in ('--config','--paths-file') and Path(argv[index+1]).is_file():
                record['inputFilesSha256'][argv[index+1]]=hashlib.sha256(Path(argv[index+1]).read_bytes()).hexdigest()
        commands.append(record)
    def audited_run(argv, *args, **kwargs):
        record_command(argv,kwargs)
        return original_run(argv, *args, **kwargs)
    def audited_popen(argv, *args, **kwargs):
        record_command(argv,kwargs)
        return original_popen(argv, *args, **kwargs)
    subprocess.run, subprocess.Popen = audited_run, audited_popen
    producer_sha = hashlib.sha256(options.executable.read_bytes()).hexdigest()
    fingerprints = {str(p.relative_to(options.source_root)): hashlib.sha256(p.read_bytes()).hexdigest()
                    for p in sorted((options.source_root / 'src' / 'rust').rglob('*')) if p.is_file()}
    for name in ('Cargo.toml', 'Cargo.lock', 'build.rs'):
        source = options.source_root / name
        if source.is_file():
            fingerprints[name] = hashlib.sha256(source.read_bytes()).hexdigest()
    source_fingerprint = hashlib.sha256(json.dumps(fingerprints, sort_keys=True).encode()).hexdigest()
    root = options.output_directory
    if sys.platform != "darwin" or not root.is_absolute() or root.exists():
        raise RuntimeError("Use native macOS and a new absolute isolated directory")
    if any(parent.is_symlink() for parent in root.parents):
        raise RuntimeError("Output ancestors must not be links")
    root.mkdir(mode=0o700)
    os.environ["PRUNLET_MACOS_QUEUE_TEST_ROOT"] = str(root / "ipc")
    assert root.stat().st_uid == os.geteuid() and stat.S_IMODE(root.stat().st_mode) == 0o700
    metadata = root / "metadata"
    metadata.mkdir(mode=0o700)
    config = root / "config.json"
    result = subprocess.run([str(options.executable), "--config", str(config), "init", "--backup-directory", str(metadata)], capture_output=True, text=True, timeout=20)
    assert result.returncode == 0, (result.stdout, result.stderr)
    cases = []
    complete = False
    tracked = []

    def identity(path):
        info = path.lstat()
        return info.st_dev, info.st_ino

    def track(path):
        device, inode = identity(path)
        tracked.append({"path":str(path),"dev":device,"ino":inode})
        fd = os.open(root.parent / (root.name + "-trash-fixture-tracking.jsonl"), os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            os.write(fd, (json.dumps(tracked[-1]) + "\n").encode())
            os.fsync(fd)
        finally:
            os.close(fd)

    def regular(path, content):
        path.write_bytes(content)
        path.chmod(0o600)
        return path

    def invoke(command, *args, env=None):
        process = subprocess.run([str(options.executable), "--config", str(config), command, *args], capture_output=True, text=True, timeout=25, env=env)
        assert process.returncode in (0, 1), (process.returncode, process.stdout, process.stderr)
        return process.returncode, json.loads(process.stdout)

    def environment(point, control):
        control.mkdir(mode=0o700)
        env = os.environ.copy()
        env["PRUNLET_MACOS_RACE_POINT"] = point
        env["PRUNLET_MACOS_RACE_ROOT"] = str(control)
        return env

    def wait_ready(control):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            try:
                return json.loads((control / "ready.json").read_bytes())
            except (FileNotFoundError, json.JSONDecodeError):
                time.sleep(0.02)
        raise AssertionError("Dedicated race barrier was not reached")

    def release(control):
        fd = os.open(control / "release", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        os.fsync(fd)
        os.close(fd)

    try:
        parent = root / "ancestor-original"
        parent.mkdir(mode=0o700)
        original = regular(parent / "entry", b"original beneath original parent")
        original_identity = identity(original)
        alternate = root / "ancestor-alternate"
        alternate.mkdir(mode=0o700)
        victim = regular(alternate / "entry", b"alternate directory must survive")
        victim_identity = identity(victim)
        parked_parent = root / "ancestor-parked"
        ancestor_control = root / "ancestor-race-control"
        env = environment("delete-before-snapshot", ancestor_control)
        process = subprocess.Popen([str(options.executable), "--config", str(config), "delete", "--", str(original)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        ready = wait_ready(ancestor_control)
        assert ready["details"]["path"] == str(original)
        assert identity(original) == original_identity
        os.rename(parent, parked_parent)
        parent.symlink_to(alternate, target_is_directory=True)
        release(ancestor_control)
        stdout, stderr = process.communicate(timeout=25)
        final = json.loads(stdout)
        assert process.returncode == 1 and final["items"][0]["status"] == "failed", (final, stderr)
        assert identity(parked_parent / "entry") == original_identity
        assert (parked_parent / "entry").read_bytes() == b"original beneath original parent"
        assert identity(victim) == victim_identity and victim.read_bytes() == b"alternate directory must survive"
        cases.append({"name": "resolved ancestor replaced with symlink preserves both directories", "passed": True, "result": final})

        target = regular(root / "queued-original", b"registered original")
        original_identity = identity(target)
        parked = root / "queued-parked"
        queue_control = root / "queue-race-control"
        env = environment("queue-before-sync", queue_control)
        code, queued = invoke("delete-queue", "--", str(target), env=env)
        assert code == 0, queued
        job = queued["jobId"]
        ready = wait_ready(queue_control)
        assert ready["details"]["jobId"] == job
        assert identity(target) == original_identity
        track(target)
        os.rename(target, parked)
        regular(target, b"replacement must survive")
        replacement_identity = identity(target)
        release(queue_control)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            code, final = invoke("delete-queue-status", job)
            if final["status"] not in ("pending", "running"):
                break
            time.sleep(0.05)
        assert code == 1 and final["status"] == "failed", final
        assert identity(parked) == original_identity and parked.read_bytes() == b"registered original"
        assert identity(target) == replacement_identity and target.read_bytes() == b"replacement must survive"
        for entry in (Path.home() / ".Trash").iterdir():
            assert identity(entry) not in (original_identity, replacement_identity)
        cases.append({"name": "queue handoff replacement preserves original and replacement", "passed": True, "jobId": job, "result": final})

        first = regular(root / "trash-first", b"first native item")
        following = regular(root / "trash-following", b"following item must survive")
        first_identity = identity(first)
        following_identity = identity(following)
        track(first)
        track(following)
        trash_control = root / "trash-race-control"
        env = environment("trash-before-result-pin", trash_control)
        process = subprocess.Popen([str(options.executable), "--config", str(config), "delete", "--", str(first), str(following)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        ready = wait_ready(trash_control)
        returned = Path(ready["details"]["resultPath"])
        assert returned.parent == Path.home() / ".Trash", returned
        assert identity(returned) == first_identity
        moved_original = root / "trash-original-parked"
        os.rename(returned, moved_original)
        substitute = regular(root / "trash-substitute", b"substitute must survive")
        substitute_identity = identity(substitute)
        os.rename(substitute, returned)
        assert identity(returned) == substitute_identity
        release(trash_control)
        stdout, stderr = process.communicate(timeout=25)
        final = json.loads(stdout)
        assert process.returncode == 1, (final, stderr)
        assert [item["status"] for item in final["items"]] == ["ambiguous", "failed"], final
        assert identity(following) == following_identity and following.read_bytes() == b"following item must survive"
        assert identity(moved_original) == first_identity and moved_original.read_bytes() == b"first native item"
        assert identity(returned) == substitute_identity and returned.read_bytes() == b"substitute must survive"
        # 今回の2実体だけをdev/inoで照合して隔離fixtureへ回収する。
        assert not substitute.exists() and not first.exists()
        os.rename(returned, substitute)
        os.rename(moved_original, first)
        assert identity(first) == first_identity and identity(substitute) == substitute_identity
        cases.append({"name": "native Trash result replacement is ambiguous and stops following target", "passed": True, "result": final})
        _, result = invoke("delete-queue-status", job)
        assert result["status"] == "failed" and result["serverPid"] == int(job.split('.')[-1])
        os.kill(result["serverPid"], signal.SIGKILL)
        complete = True
    finally:
        report = {"passed": len(cases), "failed": 0 if complete else 1, "cases": cases, "fixtureDirectory": str(root), "trackedFixtures":tracked,"retainedForReview": True}
        report.update({'producerExecutable': str(options.executable), 'producerSha256': producer_sha,
                       'sourceFingerprint': source_fingerprint, 'sourceFileSha256': fingerprints,
                       'runtimeCfg': 'debug+prunlet_macos_race_tests', 'actualCommands': commands,
                       'verificationScriptSha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest()})
        (root / "report.json").write_text(json.dumps(report, indent=2))
        print(json.dumps(report))


if __name__ == "__main__":
    main()
