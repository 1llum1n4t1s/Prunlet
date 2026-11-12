#!/usr/bin/env python3
"""専用cfgの実CLI/MCPでメモリー専用queueの境界を検証する。"""
import argparse
import hashlib
import fcntl
import json
import os
from pathlib import Path
import resource
import select
import signal
import stat
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--executable", required=True, type=Path)
    parser.add_argument("--output-directory", required=True, type=Path)
    parser.add_argument("--source-root", required=True, type=Path)
    args = parser.parse_args()
    commands = []
    mcp_inputs = []
    original_run, original_popen = subprocess.run, subprocess.Popen
    def record_command(argv,kwargs):
        argv=list(map(str,argv));record={'argv':argv,'inputFilesSha256':{}}
        for index,part in enumerate(argv[:-1]):
            if part in ('--config','--paths-file') and Path(argv[index+1]).is_file():
                record['inputFilesSha256'][argv[index+1]]=hashlib.sha256(Path(argv[index+1]).read_bytes()).hexdigest()
        if kwargs.get('input') is not None:
            data=kwargs['input'];data=data.encode() if isinstance(data,str) else data
            record['stdinSha256']=hashlib.sha256(data).hexdigest()
        commands.append(record)
    def audited_run(argv, *tail, **kwargs):
        record_command(argv,kwargs)
        return original_run(argv, *tail, **kwargs)
    def audited_popen(argv, *tail, **kwargs):
        record_command(argv,kwargs)
        return original_popen(argv, *tail, **kwargs)
    subprocess.run, subprocess.Popen = audited_run, audited_popen
    producer_sha = hashlib.sha256(args.executable.read_bytes()).hexdigest()
    fingerprints = {str(p.relative_to(args.source_root)): hashlib.sha256(p.read_bytes()).hexdigest()
                    for p in sorted((args.source_root / 'src' / 'rust').rglob('*')) if p.is_file()}
    for name in ('Cargo.toml', 'Cargo.lock', 'build.rs'):
        source = args.source_root / name
        if source.is_file(): fingerprints[name] = hashlib.sha256(source.read_bytes()).hexdigest()
    source_fingerprint = hashlib.sha256(json.dumps(fingerprints, sort_keys=True).encode()).hexdigest()
    root = args.output_directory
    assert sys.platform == "darwin" and root.is_absolute() and not root.exists()
    assert not any(p.is_symlink() for p in root.parents)
    root.mkdir(mode=0o700)
    os.environ["PRUNLET_MACOS_QUEUE_TEST_ROOT"] = str(root / "ipc")
    configs = []
    for name in ("a", "b"):
        metadata = root / (name + "-metadata")
        metadata.mkdir(mode=0o700)
        config = root / (name + "-config.json")
        result = subprocess.run([str(args.executable), "--config", str(config), "init", "--backup-directory", str(metadata)], capture_output=True, text=True, timeout=20)
        assert result.returncode == 0, (result.stdout, result.stderr)
        configs.append(config)
    jobs = []
    cases = []
    completed = False

    def invoke(command, *tail, config=None, env=None):
        if command in ("delete", "delete-queue") and "--" in tail:
            for name in tail[tail.index("--") + 1:]:
                target = Path(name)
                meta = target.lstat()
                fd = os.open(root.parent / (root.name + "-trash-fixture-tracking.jsonl"), os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
                try:
                    os.write(fd, (json.dumps({"path":str(target),"dev":meta.st_dev,"ino":meta.st_ino}) + "\n").encode())
                    os.fsync(fd)
                finally:
                    os.close(fd)
        result = subprocess.run([str(args.executable), "--config", str(config or configs[0]), command, *tail], capture_output=True, text=True, timeout=30, env=env)
        assert result.returncode in (0, 1), (result.returncode, result.stdout, result.stderr)
        value = json.loads(result.stdout)
        if command == "delete-queue" and result.returncode == 0:
            jobs.append(value["jobId"])
        return result.returncode, value

    def regular(path, contents=b"isolated IPC fixture"):
        path.write_bytes(contents)
        path.chmod(0o600)
        return path

    def check(name, action):
        action()
        cases.append({"name": name, "passed": True})

    def terminal(job, desired):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            code, result = invoke("delete-queue-status", job)
            if result["status"] == desired:
                return code, result
            assert result["status"] in ("pending", "running"), result
            time.sleep(0.05)
        raise AssertionError(result)

    def stop_verified(job):
        _, value = invoke("delete-queue-status", job)
        if value.get("serverPid"):
            assert value["serverPid"] == int(job.split('.')[-1]), value
            assert value["status"] in ("cancelled", "completed", "failed", "ambiguous", "unavailable"), value
            os.kill(value["serverPid"], signal.SIGKILL)

    try:
        def before_ack_death():
            target = regular(root / "before-ack")
            control = root / "before-ack-control"
            control.mkdir(mode=0o700)
            env = os.environ.copy()
            env["PRUNLET_MACOS_RACE_POINT"] = "queue-before-ready"
            env["PRUNLET_MACOS_RACE_ROOT"] = str(control)
            process = subprocess.Popen([str(args.executable), "--config", str(configs[0]), "delete-queue", "--", str(target)], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                try:
                    ready = json.loads((control / "ready.json").read_bytes())
                    break
                except (FileNotFoundError, json.JSONDecodeError):
                    time.sleep(0.02)
            os.kill(ready["details"]["pid"], signal.SIGKILL)
            stdout, stderr = process.communicate(timeout=20)
            result = json.loads(stdout)
            assert process.returncode == 1 and "not accepted" in result["error"], (result, stderr)
            assert target.read_bytes() == b"isolated IPC fixture"
        check("worker death before initialization ACK is non-acceptance", before_ack_death)

        def initial_worker_failure(point, kill_child):
            target=regular(root/('target-'+point))
            control=root/('control-'+point);control.mkdir(mode=0o700)
            env=os.environ.copy();env['PRUNLET_MACOS_RACE_POINT']=point;env['PRUNLET_MACOS_RACE_ROOT']=str(control)
            process=subprocess.Popen([str(args.executable),'--config',str(configs[0]),'mcp'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env)
            requests=[{'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2025-11-25','capabilities':{},'clientInfo':{'name':'pipe-failure','version':'1'}}},
                      {'jsonrpc':'2.0','method':'notifications/initialized'},
                      {'jsonrpc':'2.0','id':2,'method':'tools/call','params':{'name':'delete_files','arguments':{'action':'enqueue','paths':[str(target)]}}}]
            data=''.join(json.dumps(r)+'\n' for r in requests).encode();mcp_inputs.append({'pid':process.pid,'sha256':hashlib.sha256(data).hexdigest(),'requests':requests});process.stdin.write(data);process.stdin.flush()
            deadline=time.monotonic()+15
            while time.monotonic()<deadline:
                try: ready=json.loads((control/'ready.json').read_bytes());break
                except (FileNotFoundError,json.JSONDecodeError):time.sleep(.02)
            child=ready['details']['childPid']
            if kill_child:os.kill(child,signal.SIGKILL)
            release=os.open(control/'release',os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600);os.close(release)
            while True:
                response=json.loads(process.stdout.readline())
                if response.get('id')==2:break
            assert response['result']['isError'] is True,response
            inspected=subprocess.run(['/bin/ps','-p',str(child),'-o','stat='],capture_output=True,text=True)
            assert inspected.returncode==1 and not inspected.stdout.strip(),inspected.stdout
            request={'jsonrpc':'2.0','id':3,'method':'tools/list'};data=(json.dumps(request)+'\n').encode();mcp_inputs.append({'pid':process.pid,'sha256':hashlib.sha256(data).hexdigest(),'requests':[request]});process.stdin.write(data);process.stdin.flush()
            response=json.loads(process.stdout.readline())
            assert response['id']==3 and [tool['name'] for tool in response['result']['tools']]==['delete_files'],response
            process.stdin.close();assert process.wait(timeout=10)==0
            assert target.exists()
        check('broken initial worker pipe is reaped while the parent MCP continues serving',lambda:initial_worker_failure('queue-before-request-write',True))
        check('injected reaper creation failure destroys the captured child before start and MCP continues',lambda:initial_worker_failure('queue-reaper-thread-failure',False))

        def lost_start_ack_continues():
            target=regular(root/'lost-accepted-ack');identity=(target.stat().st_dev,target.stat().st_ino)
            control=root/'lost-ack-control';control.mkdir(mode=0o700)
            env=os.environ.copy();env['PRUNLET_MACOS_RACE_POINT']='queue-before-accepted';env['PRUNLET_MACOS_RACE_ROOT']=str(control)
            with target.open('rb') as held:
                fcntl.flock(held,fcntl.LOCK_EX|fcntl.LOCK_NB)
                code,value=invoke('delete-queue','--',str(target),env=env)
                assert code==1 and value['status']=='unavailable' and value['jobId'],value
                job=value['jobId'];jobs.append(job)
                assert json.loads((control/'ready.json').read_bytes())['details']['jobId']==job
                release=os.open(control/'release',os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600);os.close(release)
                deadline=time.monotonic()+10
                while time.monotonic()<deadline:
                    code,value=invoke('delete-queue-status',job)
                    if value['status']=='pending':break
                    time.sleep(.03)
                assert code==0 and value['status']=='pending' and target.exists(),value
            code,value=terminal(job,'completed');assert code==0 and value['result']['items'][0]['status']=='recycled',value
            matches=[p for p in (Path.home()/'.Trash').iterdir() if (p.lstat().st_dev,p.lstat().st_ino)==identity]
            assert len(matches)==1 and not target.exists();os.rename(matches[0],target)
            stop_verified(job)
        check('lost accepted ACK returns unavailable job identity while authorized worker continues after parent CLI exits',lost_start_ack_continues)

        def cross_configuration_limit():
            target = regular(root / "shared-limit")
            created=[]
            with target.open("rb") as held:
                fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                for index in range(8):
                    code, value = invoke("delete-queue", "--", str(target), config=configs[index % 2])
                    assert code == 0, value
                    created.append(value['jobId'])
                    code, value = invoke("delete-queue-cancel", value["jobId"])
                    assert code == 0 and value["status"] == "cancelled" and value["expiresUtc"], value
                confirmed = invoke("delete-queue-status", created[0])[1]
                os.kill(confirmed["serverPid"], signal.SIGSTOP)
                try:
                    code, value = invoke("delete-queue", "--", str(target), config=configs[1])
                    assert code == 1 and "limit (8)" in value["error"], value
                finally:
                    os.kill(confirmed["serverPid"], signal.SIGCONT)
                stop_verified(created[0])
                code, value = invoke("delete-queue-status", created[0])
                assert code == 1 and value["status"] == "unavailable" and "expiresUtc" in value
                code, value = invoke("delete-queue", "--", str(target), config=configs[1])
                assert code == 0, value
                invoke("delete-queue-cancel", value["jobId"])
            for job in jobs:
                stop_verified(job)
            assert target.exists()
        check("two configurations share eight retained-result slots and dead workers release admission", cross_configuration_limit)

        def mixed_gui_ssh_limit():
            app = root / 'QueueProbe.app'
            executable_directory = app / 'Contents' / 'MacOS'
            executable_directory.mkdir(mode=0o700, parents=True)
            (app / 'Contents' / 'Info.plist').write_text('<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>probe</string><key>CFBundleIdentifier</key><string>com.kagayoi.prunlet.isolatedqueueprobe</string><key>CFBundlePackageType</key><string>APPL</string><key>LSBackgroundOnly</key><true/></dict></plist>')
            source = root / 'gui-queue-probe.c'
            source.write_text(r'''#include <unistd.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc,char **argv){
 if(argc<5)return 2;
 int fd=open(argv[2],O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);if(fd<0)return 3;dup2(fd,1);close(fd);
 char side[4096];snprintf(side,sizeof side,"%s.stderr",argv[2]);fd=open(side,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);if(fd<0)return 4;dup2(fd,2);close(fd);
 snprintf(side,sizeof side,"%s.manager",argv[2]);FILE*out=fopen(side,"wx");FILE*in=popen("/bin/launchctl managername","r");char data[80]={0};if(in){fgets(data,sizeof data,in);pclose(in);}if(out){fputs(data,out);fclose(out);}
 setenv("PRUNLET_MACOS_QUEUE_TEST_ROOT",argv[1],1);execv(argv[3],argv+3);return 5;
}''')
            subprocess.run(['/usr/bin/xcrun','clang',str(source),'-o',str(executable_directory / 'probe')],check=True,capture_output=True)
            target = regular(root / 'mixed-domain')
            created = []
            with target.open('rb') as held:
                fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                for index in range(9):
                    if index % 2 == 0:
                        output = root / ('gui-admission-' + str(index) + '.json')
                        subprocess.run(['/usr/bin/open','-g','-j','-n',str(app),'--args',str(root / 'ipc'),str(output),str(args.executable),'--config',str(configs[0]),'delete-queue','--',str(target)],check=True,capture_output=True)
                        deadline = time.monotonic() + 20
                        while time.monotonic() < deadline:
                            try: value = json.loads(output.read_bytes()); break
                            except (FileNotFoundError,json.JSONDecodeError): time.sleep(.03)
                        assert Path(str(output)+'.manager').read_text().strip() == 'Aqua'
                        code = 1 if value.get('error') else 0
                        if code == 0: jobs.append(value['jobId'])
                    else:
                        code, value = invoke('delete-queue','--',str(target),config=configs[1])
                    if index < 8:
                        assert code == 0, value
                        created.append(value['jobId'])
                        invoke('delete-queue-cancel',value['jobId'])
                    else:
                        assert code == 1 and 'limit (8)' in value['error'], value
            for job in created: stop_verified(job)
            assert target.exists()
        check('Aqua and SSH Background requests share exactly eight kernel-held slots', mixed_gui_ssh_limit)

        def malformed_peer():
            source = root / 'mach-injector.c'
            source.write_text(r'''#include <mach/mach.h>
#include <servers/bootstrap.h>
#include <stdio.h>
#include <string.h>
int main(int n,char **v){
 if(n!=3)return 2;mach_port_t p=0;if(bootstrap_look_up(bootstrap_port,v[1],&p))return 3;
 unsigned char b[16384]={0};mach_msg_header_t*h=(void*)b;h->msgh_bits=MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,0);h->msgh_remote_port=p;h->msgh_id=0x50525131;
 if(!strcmp(v[2],"oversize")){h->msgh_size=sizeof b;return mach_msg(h,MACH_SEND_MSG|MACH_SEND_TIMEOUT,h->msgh_size,0,0,1000,0)?4:0;}
 mach_port_t r=0;mach_port_allocate(mach_task_self(),MACH_PORT_RIGHT_RECEIVE,&r);h->msgh_bits=MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,MACH_MSG_TYPE_MAKE_SEND_ONCE);h->msgh_local_port=r;
 const char*s=!strcmp(v[2],"probe")?"{\"action\":\"probe\"}":"{\"action\":\"cancel\"}";unsigned int l=(unsigned int)strlen(s);*(unsigned int*)(b+24)=1;*(unsigned int*)(b+28)=l;memcpy(b+32,s,l);h->msgh_size=(32+l+3)&~3;
 if(mach_msg(h,MACH_SEND_MSG|MACH_SEND_TIMEOUT,h->msgh_size,0,0,1000,0))return 5;
 memset(b,0,sizeof b);if(mach_msg(h,MACH_RCV_MSG|MACH_RCV_TIMEOUT,0,sizeof b,r,3000,0))return 6;
 if(!(h->msgh_bits&MACH_MSGH_BITS_COMPLEX)||h->msgh_size!=44)return 7;mach_msg_ool_descriptor_t*d=(void*)(b+28);if(d->type!=1||d->size>4096)return 8;fwrite(d->address,1,d->size,stdout);fputc('\n',stdout);mach_msg_destroy(h);mach_port_destroy(mach_task_self(),r);mach_port_deallocate(mach_task_self(),p);return 0;
}''')
            injector = root / 'mach-injector'
            subprocess.run(['/usr/bin/xcrun','clang','-Wno-deprecated-declarations',str(source),'-o',str(injector)],check=True,capture_output=True)
            prefix = 'com.kagayoi.prunlet.queue.' + str(os.geteuid()) + '.test.' + hashlib.sha256(os.fsencode(root / 'ipc')).hexdigest() + '.'
            def attack(job):
                name = prefix + job[0]
                for _ in range(12): subprocess.run([str(injector),name,'oversize'],check=True,capture_output=True)
                result = json.loads(subprocess.check_output([str(injector),name,'probe']))
                assert set(result) == {'status','capacityReserved'} and result['capacityReserved'] is True, result
                result = json.loads(subprocess.check_output([str(injector),name,'cancel']))
                assert result['status'] == 'unavailable' and 'result' not in result, result
            target = regular(root / 'malformed-pending')
            with target.open('rb') as held:
                fcntl.flock(held,fcntl.LOCK_EX|fcntl.LOCK_NB)
                code,value = invoke('delete-queue','--',str(target));assert code == 0, value
                attack(value['jobId'])
                assert invoke('delete-queue-status',value['jobId'])[1]['status'] == 'pending'
                invoke('delete-queue-cancel',value['jobId']);stop_verified(value['jobId'])
            assert target.exists()
            control = root / 'malformed-running-control';control.mkdir(mode=0o700)
            env = os.environ.copy();env['PRUNLET_MACOS_RACE_POINT']='queue-before-sync';env['PRUNLET_MACOS_RACE_ROOT']=str(control)
            target = regular(root / 'malformed-running')
            code,value = invoke('delete-queue','--',str(target),env=env);assert code == 0, value
            deadline = time.monotonic()+15
            while time.monotonic()<deadline:
                if (control/'ready.json').exists():break
                time.sleep(.02)
            assert invoke('delete-queue-status',value['jobId'])[1]['status'] == 'running'
            attack(value['jobId'])
            assert invoke('delete-queue-status',value['jobId'])[1]['status'] == 'running'
            os.rename(target,root/'malformed-running-original');regular(target,b'new target must survive')
            release = os.open(control/'release',os.O_CREAT|os.O_EXCL|os.O_WRONLY|os.O_NOFOLLOW,0o600);os.close(release)
            terminal(value['jobId'],'failed');stop_verified(value['jobId'])
            assert target.read_bytes() == b'new target must survive' and (root/'malformed-running-original').read_bytes() == b'isolated IPC fixture'
        check('oversized external peer preserves pending/running listener and cannot obtain capability or cancel without it',malformed_peer)

        def preserve_legacy_namespace():
            namespace = root / 'ipc'
            assert not namespace.exists()
            namespace.mkdir(mode=0o700)
            endpoint = namespace / 'unknown-operational-name'
            target = regular(root / "endpoint-request")
            victim = regular(root / "endpoint-link-victim")
            regular(endpoint, b'unknown regular must survive')
            link = namespace / 'unknown-link'
            link.symlink_to(victim)
            before = {p.name:(p.lstat().st_dev,p.lstat().st_ino,p.lstat().st_mode) for p in namespace.iterdir()}
            with target.open('rb') as held:
                fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                code, value = invoke('delete-queue', '--', str(target))
                assert code == 0, value
                parked = root / 'legacy-namespace-preserved'
                os.rename(namespace, parked)
                namespace.mkdir(mode=0o700)
                replacement = regular(namespace / 'replacement', b'replacement namespace must survive')
                assert invoke('delete-queue-status', value['jobId'])[1]['status'] == 'pending'
                invoke('delete-queue-cancel', value['jobId'])
                stop_verified(value['jobId'])
            assert {p.name:(p.lstat().st_dev,p.lstat().st_ino,p.lstat().st_mode) for p in parked.iterdir()} == before
            assert endpoint.name in before and (parked / endpoint.name).read_bytes() == b'unknown regular must survive'
            assert victim.read_bytes() == b'isolated IPC fixture' and target.exists()
            assert replacement.read_bytes() == b'replacement namespace must survive'
            os.rename(namespace, root / 'replacement-namespace-preserved')
        check('Mach queue does not touch unknown regular/symlink legacy entries or depend on namespace identity', preserve_legacy_namespace)

        def bounded_generations():
            target = regular(root / 'many-generations')
            oldest = None
            probes = []
            with target.open('rb') as held:
                fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                for index in range(24):
                    code, value = invoke('delete-queue', '--', str(target))
                    assert code == 0, value
                    probes.append(value['admissionProbes'])
                    assert 1 <= probes[-1] <= 8
                    if oldest is not None:
                        code, lost = invoke('delete-queue-status', oldest)
                        assert code == 1 and lost['status'] == 'unavailable' and lost['expiresUtc'] is None, lost
                    oldest = value['jobId']
                    invoke('delete-queue-cancel', oldest)
                    stop_verified(oldest)
            assert not (root / 'ipc').exists()
            prefix = 'com.kagayoi.prunlet.queue.' + str(os.geteuid()) + '.test.' + hashlib.sha256(os.fsencode(root / 'ipc')).hexdigest() + '.'
            names = subprocess.check_output(['/bin/launchctl', 'print', 'user/' + str(os.geteuid())], text=True)
            endpoints = {line.strip() for line in names.splitlines() if prefix in line}
            assert len(endpoints) <= 8, endpoints
            cases.append({'name':'bounded endpoint and probe observations', 'passed':True, 'generations':24, 'maxAdmissionProbes':max(probes), 'remainingEndpointNames':sorted(endpoints)})
        check('24 successive worker generations reuse eight fixed kernel slots and preserve lost results as unknown', bounded_generations)

        def expired_non_success():
            target = regular(root / "expiry")
            env = os.environ.copy()
            env["PRUNLET_MACOS_TEST_RETENTION_MS"] = "500"
            with target.open("rb") as held:
                fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                code, value = invoke("delete-queue", "--", str(target), env=env)
                assert code == 0, value
                job = value["jobId"]
                _, result = invoke("delete-queue-cancel", job)
                expiry = result["expiresUtc"]
                time.sleep(0.7)
                code, result = invoke("delete-queue-status", job)
                assert code == 1 and result["status"] == "unavailable" and result["expiresUtc"] == expiry, result
                requests = [
                    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"isolated-ipc-test","version":"1"}}},
                    {"jsonrpc":"2.0","method":"notifications/initialized"},
                    {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"delete_files","arguments":{"action":"status","jobId":job}}},
                ]
                process = subprocess.run([str(args.executable), "--config", str(configs[0]), "mcp"], input=''.join(json.dumps(r)+'\n' for r in requests), capture_output=True, text=True, timeout=20)
                assert process.returncode == 0, process.stderr
                response = next(json.loads(line) for line in process.stdout.splitlines() if json.loads(line).get("id") == 2)
                assert response["result"]["isError"] is True and response["result"]["structuredContent"]["status"] == "unavailable", response
            stop_verified(job)
        check("expired result has final expiresUtc and fails CLI and MCP", expired_non_success)

        def node_and_parent_limit():
            soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
            assert hard == resource.RLIM_INFINITY or hard >= 8192
            resource.setrlimit(resource.RLIMIT_NOFILE, (max(soft, 8192), hard))
            directory = root / "large-limit"
            directory.mkdir(mode=0o700)
            parent_count = len(list(directory.parents))
            for index in range(4096 - parent_count):
                regular(directory / str(index), b"")
            code, value = invoke("delete-queue", "--recursive", "--", str(directory))
            assert code == 1 and "4096" in value["error"], value
            assert len(list(directory.iterdir())) == 4096 - parent_count
            # 1項目を別fixtureへ移し、親を含め4096ちょうどで同じ実経路を通す。
            parked = root / "large-extra"
            os.rename(directory / "0", parked)
            root_identity = (directory.stat().st_dev, directory.stat().st_ino)
            fd = os.open(root.parent / (root.name + "-trash-fixture-tracking.jsonl"), os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            try:
                os.write(fd, (json.dumps({"path":str(directory),"dev":root_identity[0],"ino":root_identity[1]}) + "\n").encode())
                os.fsync(fd)
            finally:
                os.close(fd)
            with (directory / "1").open("rb") as held:
                fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                code, value = invoke("delete-queue", "--recursive", "--", str(directory))
                assert code == 0, value
                job = value["jobId"]
                assert invoke("delete-queue-status", job)[1]["status"] == "pending"
            code, value = terminal(job, "completed")
            assert code == 0 and value["result"]["items"][0]["status"] == "recycled", value
            matches = [p for p in (Path.home() / ".Trash").iterdir() if (p.lstat().st_dev, p.lstat().st_ino) == root_identity]
            assert len(matches) == 1 and not directory.exists()
            os.rename(matches[0], directory)
            assert len(list(directory.iterdir())) == 4095 - parent_count
            stop_verified(job)
        check("4096 cap includes ancestors and retained descriptors are reused through real Trash", node_and_parent_limit)

        def large_ool_result():
            directory = root / 'large-ool'
            directory.mkdir(mode=0o700)
            targets = [regular(directory / (str(index).zfill(3) + '-' + 'x' * 220), b'bounded OOL fixture') for index in range(256)]
            identities = {p:(p.stat().st_dev,p.stat().st_ino) for p in targets}
            tracking = root.parent / (root.name + '-trash-fixture-tracking.jsonl')
            fd = os.open(tracking,os.O_WRONLY|os.O_APPEND|os.O_CREAT|os.O_NOFOLLOW,0o600)
            try:
                for p,identity in identities.items(): os.write(fd,(json.dumps({'path':str(p),'dev':identity[0],'ino':identity[1]})+'\n').encode())
                os.fsync(fd)
            finally: os.close(fd)
            paths_file = root / 'large-ool-paths.json'
            paths_file.write_text(json.dumps(list(map(str, targets))))
            code, value = invoke('delete-queue','--paths-file',str(paths_file))
            assert code == 0, value
            job = value['jobId']
            code, value = terminal(job,'completed')
            assert code == 0 and len(value['result']['items']) == 256 and len(json.dumps(value)) > 65536
            assert all(item['status'] == 'recycled' for item in value['result']['items'])
            found = {(p.lstat().st_dev,p.lstat().st_ino):p for p in (Path.home()/'.Trash').iterdir()}
            for target,identity in identities.items():
                assert not target.exists() and identity in found
                os.rename(found[identity],target)
                assert target.read_bytes() == b'bounded OOL fixture'
            stop_verified(job)
        check('bounded Mach OOL response returns over 64KiB through actual CLI and restores 256 native Trash fixtures',large_ool_result)

        def reject_unknown_acl():
            parent = root / "acl-parent"
            parent.mkdir(mode=0o700)
            result = subprocess.run(["/bin/chmod", "+a", "everyone allow read,write,execute,file_inherit,directory_inherit", str(parent)], capture_output=True, text=True)
            assert result.returncode == 0, result.stderr
            before = subprocess.check_output(["/bin/ls", "-led", str(parent)])
            new_config = parent / "must-not-create.json"
            process = subprocess.run([str(args.executable), "--config", str(new_config), "init", "--backup-directory", str(root / "a-metadata")], capture_output=True, text=True, timeout=20)
            assert process.returncode == 1 and "ACL" in process.stdout and not new_config.exists(), (process.stdout, process.stderr)
            assert subprocess.check_output(["/bin/ls", "-led", str(parent)]) == before
        check("unknown inherited ACL refuses creation without rewriting the ACL", reject_unknown_acl)

        def physical_protection():
            protected = root / "RecoveryCase"
            protected.mkdir(mode=0o700)
            child = regular(protected / "entry")
            alternative = root / "recoverycase" / "entry"
            assert alternative.exists() and alternative.stat().st_ino == child.stat().st_ino, "This case requires case-insensitive APFS"
            special = root / "physical-config.json"
            value = json.loads(configs[0].read_bytes())
            value["volumeRecoveryDirectories"] = {"fixture": str(protected)}
            special.write_text(json.dumps(value))
            special.chmod(0o600)
            code, result = invoke("delete", "--", str(alternative), config=special)
            assert code == 1 and result["items"][0]["status"] == "failed" and child.exists(), result
            ordinary = root / "OverlapCase"
            ordinary.mkdir(mode=0o700)
            entry = regular(ordinary / "entry")
            code, result = invoke("delete", "--recursive", "--", str(ordinary), str(root / "overlapcase" / "entry"))
            assert code == 1 and all(item["status"] == "failed" for item in result["items"]) and entry.exists(), result
        check("native APFS identities protect recovery aliases and reject case-alias overlap", physical_protection)

        def waiting_progress():
            target = regular(root / "waiting-progress")
            lock = root / "a-metadata" / "maintenance.lock"
            with lock.open("r+b") as held:
                fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                process = subprocess.Popen([str(args.executable), "--config", str(configs[0]), "delete", "--dry-run", "--", str(target)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                ready, _, _ = select.select([process.stderr], [], [], 5)
                assert ready and b"Waiting for" in process.stderr.readline()
            stdout, stderr = process.communicate(timeout=20)
            assert process.returncode == 0 and json.loads(stdout)["items"][0]["status"] == "would_recycle", (stdout, stderr)
            with lock.open("r+b") as held:
                fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                process = subprocess.Popen([str(args.executable), "--config", str(configs[0]), "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                requests = [
                    {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"wait-progress-test","version":"1"}}},
                    {"jsonrpc":"2.0","method":"notifications/initialized"},
                    {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"delete_files","arguments":{"paths":[str(target)],"dryRun":True},"_meta":{"progressToken":"wait-test"}}},
                ]
                data=''.join(json.dumps(r)+'\n' for r in requests).encode()
                mcp_inputs.append({'pid':process.pid,'sha256':hashlib.sha256(data).hexdigest(),'requests':requests})
                process.stdin.write(data)
                process.stdin.flush()
                time.sleep(1.2)
            stdout, stderr = process.communicate(timeout=20)
            events = [json.loads(line) for line in stdout.splitlines()]
            final_index = next(i for i, e in enumerate(events) if e.get("id") == 2)
            assert process.returncode == 0 and events[final_index]["result"]["isError"] is False, (events, stderr)
            assert any(e.get("params", {}).get("progressToken") == "wait-test" and "Waiting" in e.get("params", {}).get("message", "") for e in events[:final_index])
            assert not any(e.get("params", {}).get("progressToken") == "wait-test" for e in events[final_index+1:])
            assert target.exists()
        check("coordination wait reports CLI stderr and MCP token progress until final response", waiting_progress)

        def memory_only():
            for name in ("a", "b"):
                assert sorted(p.name for p in (root / (name + "-metadata")).iterdir()) == ["maintenance.lock"]
            assert not (root / 'ipc').exists()
        check("Mach product control creates no paths identities results locks or sockets on disk", memory_only)
        completed = True
    finally:
        for job in jobs:
            try:
                stop_verified(job)
            except (ProcessLookupError, AssertionError):
                pass
        report = {"passed":len(cases),"failed":0 if completed else 1,"cases":cases,"fixtureDirectory":str(root),"testArtifactUsesIsolatedNamespace":True,"retainedForReview":True}
        report.update({'producerExecutable':str(args.executable),'producerSha256':producer_sha,
                       'sourceFingerprint':source_fingerprint,'sourceFileSha256':fingerprints,
                       'runtimeCfg':'debug+prunlet_macos_race_tests','actualCommands':commands,
                       'verificationScriptSha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'mcpInputs':mcp_inputs})
        (root / "report.json").write_text(json.dumps(report, indent=2))
        print(json.dumps(report))


if __name__ == "__main__":
    main()
