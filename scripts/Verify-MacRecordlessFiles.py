#!/usr/bin/env python3
"""macOS native Trashを新規の専用fixtureだけで検証する。既存Trashの清掃は行わない。"""
import argparse
import hashlib
import fcntl
import json
import os
from pathlib import Path
import select
import signal
import stat
import subprocess
import sys
import time

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--executable', required=True, type=Path)
    parser.add_argument('--output-directory', required=True, type=Path)
    parser.add_argument('--race-tests', action='store_true')
    parser.add_argument('--artifact-profile', choices=('debug', 'release'), default='debug')
    parser.add_argument('--source-root', required=True, type=Path)
    options = parser.parse_args()
    if options.race_tests and options.artifact_profile != 'debug':
        parser.error('--race-tests requires --artifact-profile debug')
    producer_sha = hashlib.sha256(options.executable.read_bytes()).hexdigest()
    fingerprints = {str(p.relative_to(options.source_root)): hashlib.sha256(p.read_bytes()).hexdigest()
                    for p in sorted((options.source_root / 'src' / 'rust').rglob('*')) if p.is_file()}
    for name in ('Cargo.toml', 'Cargo.lock', 'build.rs'):
        source = options.source_root / name
        if source.is_file():
            fingerprints[name] = hashlib.sha256(source.read_bytes()).hexdigest()
    source_fingerprint = hashlib.sha256(json.dumps(fingerprints, sort_keys=True).encode()).hexdigest()
    commands = []
    mcp_inputs = []
    original_run, original_popen = subprocess.run, subprocess.Popen
    def command_record(argv, kwargs, kind):
        argv=list(map(str,argv));record={'argv':argv,'kind':kind,'inputFilesSha256':{}}
        for index,part in enumerate(argv[:-1]):
            if part in ('--config','--paths-file') and Path(argv[index+1]).is_file():
                record['inputFilesSha256'][argv[index+1]]=hashlib.sha256(Path(argv[index+1]).read_bytes()).hexdigest()
        if kwargs.get('input') is not None:
            data=kwargs['input'];data=data.encode() if isinstance(data,str) else data
            record['stdinSha256']=hashlib.sha256(data).hexdigest()
        commands.append(record)
    def audited_run(argv, *args, **kwargs):
        command_record(argv,kwargs,'run')
        return original_run(argv, *args, **kwargs)
    def audited_popen(argv, *args, **kwargs):
        command_record(argv,kwargs,'process')
        return original_popen(argv, *args, **kwargs)
    subprocess.run, subprocess.Popen = audited_run, audited_popen
    race_literal_present = b'PRUNLET_MACOS_QUEUE_TEST_ROOT' in options.executable.read_bytes()
    assert race_literal_present == options.race_tests, 'artifact cfg does not match requested validation mode'
    if sys.platform != 'darwin':
        raise RuntimeError('This verification requires native macOS')
    root = options.output_directory
    if not root.is_absolute() or root.exists():
        raise RuntimeError('Use a new absolute output directory')
    for parent in root.parents:
        if parent.is_symlink():
            raise RuntimeError('Output ancestors must not be symbolic links')
    root.mkdir(mode=0o700)
    if options.race_tests:
        os.environ['PRUNLET_MACOS_QUEUE_TEST_ROOT'] = str(root / 'ipc')
    if root.stat().st_uid != os.geteuid() or stat.S_IMODE(root.stat().st_mode) != 0o700:
        raise RuntimeError('Output root must be owned and private')
    config = root / 'config.json'
    metadata = root / 'metadata'
    metadata.mkdir(mode=0o700)
    initialized = subprocess.run([str(options.executable), '--config', str(config), 'init', '--backup-directory', str(metadata)], capture_output=True, text=True, timeout=30)
    assert initialized.returncode == 0, (initialized.stdout, initialized.stderr)
    assert json.loads(initialized.stdout)['status'] == 'initialized'
    results = []
    trash_fixtures = []
    completed = False
    observed_exits = []
    owned_jobs = []

    def has_failure(value):
        if isinstance(value, dict):
            return bool(value.get('error')) or value.get('status') in ('failed', 'ambiguous', 'unavailable') or any((has_failure(value.get(k)) for k in ('items', 'result')))
        if isinstance(value, list):
            return any((has_failure(item) for item in value))
        return False

    def invoke(command, args, use_config=None):
        if command in ('delete', 'delete-queue') and not args.get('dryRun'):
            for name in args['paths']:
                try:
                    target = Path(name)
                    meta = target.lstat()
                    log_target(target, (meta.st_dev, meta.st_ino))
                except FileNotFoundError:
                    pass
        prefix = [str(options.executable), '--config', str(use_config or config), command]
        if command == 'delete' or command == 'delete-queue':
            paths_file = root / ('paths-' + str(len(results)) + '.json')
            paths_file.write_text(json.dumps(args['paths']))
            invocation = prefix[:]
            if args.get('recursive'):
                invocation.append('--recursive')
            if args.get('dryRun'):
                invocation.append('--dry-run')
            invocation += ['--paths-file', str(paths_file)]
        else:
            invocation = prefix + [args['jobId']]
        process = subprocess.run(invocation, capture_output=True, text=True, timeout=30)
        if not process.stdout.strip():
            raise AssertionError((invocation, process.returncode, process.stderr))
        parsed = json.loads(process.stdout)
        if command == 'delete-queue' and parsed.get('jobId') and (parsed.get('status') == 'pending'):
            owned_jobs.append(parsed['jobId'])
        expected = 1 if has_failure(parsed) else 0
        assert process.returncode == expected, (command, process.returncode, expected, parsed, process.stderr)
        observed_exits.append({'command': command, 'exitCode': process.returncode})
        return parsed

    def check(name, callback):
        callback()
        results.append({'name': name, 'passed': True})

    def create(name, data=b'Prunlet macOS isolated fixture\x00\xff'):
        target = root / name
        target.write_bytes(data)
        target.chmod(0o600)
        return target

    def track(target, identity):
        trash_fixtures.append((target, identity))
        log_target(target, identity)

    def log_target(target, identity):
        record = json.dumps({'path': str(target), 'dev': identity[0], 'ino': identity[1]}) + '\n'
        fd = os.open(root.parent / (root.name + '-trash-fixture-tracking.jsonl'), os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            os.write(fd, record.encode())
            os.fsync(fd)
        finally:
            os.close(fd)

    def status(result):
        return result['items'][0]['status']

    def restore_fixture(target, identity):
        trash = Path.home() / '.Trash'
        matches = [p for p in trash.iterdir() if (p.lstat().st_dev, p.lstat().st_ino) == identity]
        assert len(matches) == 1, ('Trash identity', identity, matches)
        assert not target.exists() and (not target.is_symlink())
        os.rename(matches[0], target)
        assert (target.lstat().st_dev, target.lstat().st_ino) == identity
    try:
        ordinary = create('空白 unicode.txt')
        original = ordinary.read_bytes()
        identity = (ordinary.stat().st_dev, ordinary.stat().st_ino)

        def dry_run():
            assert status(invoke('delete', {'paths': [str(ordinary)], 'dryRun': True})) == 'would_recycle'
            assert ordinary.read_bytes() == original
            assert not any((p.name != 'maintenance.lock' for p in metadata.iterdir()))
        check('dry-run preserves bytes and creates no operation record', dry_run)

        def native_trash():
            track(ordinary, identity)
            assert status(invoke('delete', {'paths': [str(ordinary)]})) == 'recycled'
            assert not ordinary.exists()
            restore_fixture(ordinary, identity)
            trash_fixtures.clear()
            assert ordinary.read_bytes() == original
        check('native Trash returned identity and fixture roundtrip', native_trash)

        def mac_native_name():
            target = create('NUL')
            native_id = (target.stat().st_dev, target.stat().st_ino)
            track(target, native_id)
            assert status(invoke('delete', {'paths': [str(target)]})) == 'recycled'
            restore_fixture(target, native_id)
            trash_fixtures.clear()
        check('Windows reserved spelling uses ordinary macOS Trash without permanent deletion', mac_native_name)

        def preflight():
            bad = root / 'ancestor-link'
            bad.symlink_to(root, target_is_directory=True)
            result = invoke('delete', {'paths': [str(ordinary), str(bad / '空白 unicode.txt')]})
            assert all((item['status'] == 'failed' for item in result['items']))
            assert ordinary.read_bytes() == original
        check('ancestor symlink rejection preserves all targets', preflight)

        def overlap():
            result = invoke('delete', {'paths': [str(root), str(ordinary)], 'recursive': True})
            assert all((item['status'] == 'failed' for item in result['items']))
            assert ordinary.exists()
        check('overlap and metadata ancestor rejected', overlap)

        def protected():
            assert status(invoke('delete', {'paths': [str(metadata)], 'recursive': True})) == 'failed'
            assert status(invoke('delete', {'paths': [str(config)]})) == 'failed'
        check('metadata and configuration protected', protected)

        def known_system_aliases():
            alias_config = root / 'alias-config.json'
            for alias in ('/tmp', '/var', '/etc'):
                contents = json.dumps({'backupDirectory': alias}).encode()
                alias_config.write_bytes(contents)
                alias_config.chmod(0o600)
                process = subprocess.run([str(options.executable), '--config', str(alias_config), 'validate-config'], capture_output=True, text=True, timeout=20)
                assert process.returncode == 1 and 'Metadata root must be private' in json.loads(process.stdout)['error'], (alias, process.stdout, process.stderr)
                observed_exits.append({'command': 'validate-config', 'exitCode': process.returncode})
                assert alias_config.read_bytes() == contents
        check('known system aliases resolve safely and public metadata roots are refused without writes', known_system_aliases)

        def hardlink():
            first = create('hardlink-source')
            alias = root / 'hardlink-alias'
            os.link(first, alias)
            first_id = (first.stat().st_dev, first.stat().st_ino)
            track(first, first_id)
            assert status(invoke('delete', {'paths': [str(first)]})) == 'recycled'
            assert alias.read_bytes() == original
            restore_fixture(first, first_id)
            trash_fixtures.clear()
            assert first.stat().st_ino == alias.stat().st_ino
        check('hardlink alias and content preserved', hardlink)

        def hardlink_batch():
            first = create('batch-hardlink-first')
            second = root / 'batch-hardlink-second'
            os.link(first, second)
            identity = (first.stat().st_dev, first.stat().st_ino)
            track(first, identity)
            track(second, identity)
            result = invoke('delete', {'paths': [str(first), str(second)]})
            assert [i['status'] for i in result['items']] == ['recycled', 'recycled'], result
            matches = [p for p in (Path.home() / '.Trash').iterdir() if (p.lstat().st_dev, p.lstat().st_ino) == identity]
            assert len(matches) == 2
            for source, target in zip(matches, (first, second)):
                os.rename(source, target)
            assert first.stat().st_ino == second.stat().st_ino
            trash_fixtures.clear()
        check('multiple hardlink names share serialized identity verification', hardlink_batch)

        def config_alias():
            special_config = root / 'special-config.json'
            special_config.write_bytes(config.read_bytes())
            special_config.chmod(0o600)
            alias = root / 'config-hardlink'
            os.link(special_config, alias)
            try:
                result = invoke('delete', {'paths': [str(alias)]}, use_config=special_config)
                assert result.get('items') and status(result) == 'failed' or 'single-link' in str(result), result
            except AssertionError as error:
                assert 'single-link' in str(error), error
            assert special_config.exists() and alias.exists()

        def symlink_leaf():
            link = root / 'leaf-link'
            link.symlink_to(ordinary)
            link_id = (link.lstat().st_dev, link.lstat().st_ino)
            track(link, link_id)
            assert status(invoke('delete', {'paths': [str(link)]})) == 'recycled'
            assert ordinary.read_bytes() == original
            restore_fixture(link, link_id)
            trash_fixtures.clear()
            assert link.is_symlink()
        check('leaf symlink is trashed without following target', symlink_leaf)

        def recursive():
            directory = root / 'recursive'
            directory.mkdir()
            (directory / 'child').write_bytes(b'child')
            tree_id = (directory.stat().st_dev, directory.stat().st_ino)
            assert status(invoke('delete', {'paths': [str(directory)]})) == 'failed'
            track(directory, tree_id)
            assert status(invoke('delete', {'paths': [str(directory)], 'recursive': True})) == 'recycled'
            restore_fixture(directory, tree_id)
            trash_fixtures.clear()
            assert (directory / 'child').read_bytes() == b'child'
        check('recursive opt-in and tree roundtrip', recursive)

        def large_recursive():
            directory = root / 'large-recursive'
            directory.mkdir()
            for index in range(5000):
                (directory / str(index)).write_bytes(b'large tree child')
            identity = (directory.stat().st_dev, directory.stat().st_ino)
            track(directory, identity)
            assert status(invoke('delete', {'paths': [str(directory)], 'recursive': True})) == 'recycled'
            restore_fixture(directory, identity)
            trash_fixtures.clear()
            assert len(list(directory.iterdir())) == 5000
            assert (directory / '4999').read_bytes() == b'large tree child'
        check('synchronous native Trash accepts 5000 children without queue reservation limit', large_recursive)

        def concurrent_requests():
            target = create('concurrent')
            identity = (target.stat().st_dev, target.stat().st_ino)
            argv = [str(options.executable), '--config', str(config), 'delete', '--', str(target)]
            track(target, identity)
            processes = [subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE) for _ in range(2)]
            statuses = []
            for process in processes:
                stdout, stderr = process.communicate(timeout=20)
                value = json.loads(stdout)
                assert process.returncode == 0, (value, stderr)
                observed_exits.append({'command': 'delete-concurrent', 'exitCode': process.returncode})
                statuses.append(status(value))
            assert sorted(statuses) == ['already_absent', 'recycled'], statuses
            restore_fixture(target, identity)
            trash_fixtures.clear()
        check('concurrent CLI requests serialize the same object without duplicate deletion', concurrent_requests)

        def wait_status(job, expected):
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                result = invoke('delete-queue-status', {'jobId': job})
                if result['status'] == expected:
                    return result
                if result['status'] in ('failed', 'ambiguous', 'completed', 'cancelled'):
                    raise AssertionError(result)
                time.sleep(0.25)
            raise AssertionError((job, expected, result))

        def cancellation():
            target = create('queue-cancel')
            with target.open('rb') as held:
                fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                queued = invoke('delete-queue', {'paths': [str(target)]})
                wait_status(queued['jobId'], 'pending')
                cancelled = invoke('delete-queue-cancel', {'jobId': queued['jobId']})
                assert cancelled['status'] == 'cancelled'
            assert target.exists()
        check('advisory-lock pending queue cancellation', cancellation)

        def queue_release():
            target = create('queue-release')
            target_id = (target.stat().st_dev, target.stat().st_ino)
            track(target, target_id)
            with target.open('rb') as held:
                fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                queued = invoke('delete-queue', {'paths': [str(target)]})
                wait_status(queued['jobId'], 'pending')
                assert target.exists()
            final = wait_status(queued['jobId'], 'completed')
            assert status(final['result']) == 'recycled'
            restore_fixture(target, target_id)
            trash_fixtures.clear()
        check('queue survives submitting process exit and trashes after advisory unlock', queue_release)

        def changed_queued_object():
            target = create('queue-change')
            with target.open('rb') as held:
                fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                queued = invoke('delete-queue', {'paths': [str(target)]})
                wait_status(queued['jobId'], 'pending')
                target.write_bytes(b'changed after enqueue')
            wait_status(queued['jobId'], 'failed')
            assert target.read_bytes() == b'changed after enqueue'
        check('queued content change fails without automatic resend', changed_queued_object)

        def changed_queued_tree():
            directory = root / 'queue-tree'
            directory.mkdir()
            target = directory / 'held'
            target.write_bytes(b'held')
            with target.open('rb') as held:
                fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                queued = invoke('delete-queue', {'paths': [str(directory)], 'recursive': True})
                wait_status(queued['jobId'], 'pending')
                (directory / 'added').write_bytes(b'not in original request')
            wait_status(queued['jobId'], 'failed')
            assert target.exists() and (directory / 'added').exists()
        check('recursive queue rejects added child', changed_queued_tree)

        def changed_parent():
            directory = root / 'queue-parent'
            directory.mkdir()
            target = directory / 'held'
            target.write_bytes(b'original')
            moved = root / 'queue-parent-original'
            with target.open('rb') as held:
                fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                queued = invoke('delete-queue', {'paths': [str(target)]})
                wait_status(queued['jobId'], 'pending')
                directory.rename(moved)
                directory.mkdir()
                target.write_bytes(b'replacement')
            wait_status(queued['jobId'], 'failed')
            assert target.read_bytes() == b'replacement'
            assert (moved / 'held').read_bytes() == b'original'
        check('queue detects replaced parent and name', changed_parent)

        def queue_limits_and_retention():
            target = create('queue-limit')
            ids = []
            with target.open('rb') as held:
                fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                for _ in range(3):
                    queued = invoke('delete-queue', {'paths': [str(target)]})
                    ids.append(queued['jobId'])
                    assert invoke('delete-queue-cancel', {'jobId': ids[-1]})['status'] == 'cancelled'
                try:
                    result = invoke('delete-queue', {'paths': [str(target)]})
                    assert 'limit (8)' in str(result), result
                except AssertionError as error:
                    assert 'limit (8)' in str(error), error
                confirmed = invoke('delete-queue-status', {'jobId': ids[0]})
                assert confirmed['serverPid'] == int(ids[0].split('.')[-1])
                os.kill(confirmed['serverPid'], signal.SIGKILL)
                assert invoke('delete-queue-status', {'jobId': ids[0]})['status'] == 'unavailable'
                queued = invoke('delete-queue', {'paths': [str(target)]})
                assert invoke('delete-queue-cancel', {'jobId': queued['jobId']})['status'] == 'cancelled'
            assert target.exists()
            for job in owned_jobs:
                confirmed = invoke('delete-queue-status', {'jobId': job})
                if confirmed.get('serverPid'):
                    assert confirmed['status'] in ('cancelled', 'completed', 'failed'), confirmed
                    os.kill(confirmed['serverPid'], signal.SIGKILL)
        check('queue admission counts retained results and releases lost worker slots', queue_limits_and_retention)

        def memory_only_control():
            assert sorted((p.name for p in metadata.iterdir())) == ['maintenance.lock']
            namespace = Path(os.environ['PRUNLET_MACOS_QUEUE_TEST_ROOT'])
            assert not namespace.exists(), 'Mach queue must create no filesystem control namespace'
        if options.race_tests:
            check('queue paths identities and results are absent from disk control', memory_only_control)
        mcp_metadata = root / 'mcp-metadata'
        mcp_metadata.mkdir(mode=0o700)
        mcp_config = root / 'mcp-config.json'
        initialized = subprocess.run([str(options.executable), '--config', str(mcp_config), 'init', '--backup-directory', str(mcp_metadata)], capture_output=True, text=True, timeout=30)
        assert initialized.returncode == 0, (initialized.stdout, initialized.stderr)

        class Rpc:

            def __init__(self):
                self.process = subprocess.Popen([str(options.executable), '--config', str(mcp_config), 'mcp'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
                self.sequence = 0
                self.buffer = b''
                self.events = []
                self.token_calls = {}
                self.request('initialize', {'protocolVersion': '2025-11-25', 'capabilities': {}, 'clientInfo': {'name': 'isolated-mac-e2e', 'version': '1'}})
                self.notify('notifications/initialized', {})

            def notify(self, method, params):
                data=(json.dumps({'jsonrpc': '2.0', 'method': method, 'params': params}) + '\n').encode()
                mcp_inputs.append({'pid':self.process.pid,'sha256':hashlib.sha256(data).hexdigest(),'json':json.loads(data)})
                self.process.stdin.write(data)

            def request(self, method, params, error_expected=False):
                self.sequence += 1
                request_id = self.sequence
                data=(json.dumps({'jsonrpc': '2.0', 'id': request_id, 'method': method, 'params': params}) + '\n').encode()
                mcp_inputs.append({'pid':self.process.pid,'sha256':hashlib.sha256(data).hexdigest(),'json':json.loads(data)})
                self.process.stdin.write(data)
                deadline = time.monotonic() + 20
                while time.monotonic() < deadline:
                    if b'\n' not in self.buffer:
                        ready, _, _ = select.select([self.process.stdout], [], [], max(0, deadline - time.monotonic()))
                        if not ready:
                            break
                        data = os.read(self.process.stdout.fileno(), 65536)
                        if not data:
                            break
                        self.buffer += data
                        continue
                    line, self.buffer = self.buffer.split(b'\n', 1)
                    event = json.loads(line)
                    self.events.append(event)
                    if event.get('id') == request_id:
                        if error_expected:
                            return event['error']
                        assert 'error' not in event, event
                        return event['result']
                raise AssertionError(('MCP response timeout or EOF', method, self.events))

            def call(self, args, token=None, name='delete_files'):
                if name == 'delete_files' and not args.get('dryRun'):
                    for path in args.get('paths', []):
                        target = Path(path)
                        meta = target.lstat()
                        log_target(target, (meta.st_dev, meta.st_ino))
                params = {'name': name, 'arguments': args}
                if token is not None:
                    params['_meta'] = {'progressToken': token}
                    self.token_calls[token] = self.sequence + 1
                return self.request('tools/call', params)

            def close(self):
                self.process.stdin.close()
                assert self.process.wait(timeout=20) == 0, self.process.stderr.read().decode()
                tail = self.buffer + self.process.stdout.read()
                for line in tail.splitlines():
                    self.events.append(json.loads(line))
                self.process.stdout.close()
                self.process.stderr.close()

        def mcp_native_and_contract():
            rpc = Rpc()
            try:
                assert [tool['name'] for tool in rpc.request('tools/list', {})['tools']] == ['delete_files']
                target = create('mcp-native')
                identity = (target.stat().st_dev, target.stat().st_ino)
                dry = rpc.call({'paths': [str(target)], 'dryRun': True}, token='mac-dry')
                assert dry['isError'] is False and status(dry['structuredContent']) == 'would_recycle'
                assert target.exists()
                track(target, identity)
                deleted = rpc.call({'paths': [str(target)]}, token='mac-trash')
                assert deleted['isError'] is False and status(deleted['structuredContent']) == 'recycled'
                restore_fixture(target, identity)
                trash_fixtures.clear()
                unsupported = rpc.request('tools/call', {'name': 'list_operations'}, error_expected=True)
                assert unsupported['code'] == -32602
                assert rpc.call({'paths': [str(target)], 'dryRun': True})['isError'] is False
            finally:
                rpc.close()
            for token in ('mac-dry', 'mac-trash'):
                progress_events = [e for e in rpc.events if e.get('method') == 'notifications/progress' and e.get('params', {}).get('progressToken') == token]
                assert progress_events, (token, rpc.events)
                final_index = next((i for i, e in enumerate(rpc.events) if e.get('id') == rpc.token_calls[token]))
                assert all((e.get('params', {}).get('progressToken') != token for e in rpc.events[final_index + 1:]))
            assert not any((p.name != 'maintenance.lock' for p in mcp_metadata.iterdir()))
        check('real stdio MCP lists only the macOS file tool, uses native Trash and rejects registry', mcp_native_and_contract)

        def mcp_eof_queue():
            target = create('mcp-eof-queue')
            identity = (target.stat().st_dev, target.stat().st_ino)
            track(target, identity)
            with target.open('rb') as held:
                fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                rpc = Rpc()
                try:
                    result = rpc.call({'paths': [str(target)], 'action': 'enqueue'})
                    assert result['isError'] is False, result
                    job = result['structuredContent']['jobId']
                    owned_jobs.append(job)
                    pending = rpc.call({'action': 'status', 'jobId': job})
                    assert pending['structuredContent']['status'] == 'pending', pending
                finally:
                    rpc.close()
                assert target.exists()
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                final = invoke('delete-queue-status', {'jobId': job}, use_config=mcp_config)
                if final['status'] == 'completed':
                    break
                assert final['status'] in ('pending', 'running'), final
                time.sleep(0.25)
            assert final['status'] == 'completed', final
            assert status(final['result']) == 'recycled'
            restore_fixture(target, identity)
            trash_fixtures.clear()
        check('real MCP enqueue survives stdin EOF and removes only after advisory unlock', mcp_eof_queue)

        def mcp_cancel():
            target = create('mcp-cancel')
            with target.open('rb') as held:
                fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                rpc = Rpc()
                try:
                    result = rpc.call({'paths': [str(target)], 'action': 'enqueue'})
                    assert result['isError'] is False, result
                    job = result['structuredContent']['jobId']
                    owned_jobs.append(job)
                    cancelled = rpc.call({'action': 'cancel', 'jobId': job})
                    assert cancelled['structuredContent']['status'] == 'cancelled', cancelled
                finally:
                    rpc.close()
            assert target.exists()
        check('real MCP pending cancellation preserves fixture', mcp_cancel)
        check('protected configuration hardlink cannot bypass identity guard', config_alias)
        for job in owned_jobs:
            confirmed = invoke('delete-queue-status', {'jobId': job})
            if confirmed.get('serverPid'):
                assert confirmed['status'] in ('cancelled', 'completed', 'failed'), confirmed
                assert confirmed['serverPid'] == int(job.split('.')[-1])
                os.kill(confirmed['serverPid'], signal.SIGKILL)
        completed = True
    finally:
        report = {'passed': len(results), 'failed': 0 if completed else 1, 'cases': results, 'cliInvocationsWithValidatedExitCode': len(observed_exits), 'observedCliExits': sorted({(e['command'], e['exitCode']) for e in observed_exits}), 'fixtureDirectory': str(root), 'retainedForReview': True, 'pendingTrashFixtures': [{'path': str(p), 'dev': i[0], 'ino': i[1]} for p, i in trash_fixtures]}
        report.update({'producerExecutable': str(options.executable), 'producerSha256': producer_sha,
                       'sourceFingerprint': source_fingerprint, 'sourceFileSha256': fingerprints,
                       'runtimeCfg': 'debug+prunlet_macos_race_tests' if options.race_tests else 'normal-' + options.artifact_profile,
                       'artifactProfileDeclared': options.artifact_profile,
                       'artifactProfileEvidence': 'caller declaration; bind to build manifest and producerSha256',
                       'testOverrideLiteralPresent': race_literal_present, 'actualCommands': commands,
                       'verificationScriptSha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'mcpInputs':mcp_inputs})
        (root / 'report.json').write_text(json.dumps(report, indent=2, ensure_ascii=False))
        print(json.dumps(report, ensure_ascii=False))
if __name__ == '__main__':
    main()
