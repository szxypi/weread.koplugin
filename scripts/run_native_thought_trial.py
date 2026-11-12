#!/usr/bin/env python3
"""Disposable native UI trial. Private duplex pipes; no saved credentials."""
import argparse
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import tempfile
import time
import zipfile

from native_trial_pipe import Frames,MAX_FRAME,read_initial,reply,write_initial
from run_persistent_ui_probe import extract_candidate

FLAGS={'anonymous_credentials','native_ui','guard_installed','worker_heartbeat','journal_before_post',
       'no_authentication_posts','credential_audit','workers_reaped','local_pending_kept','dispatch_blocked','cache_verified','permit_writes'}
COUNTS={'steps':3,'requests':32,'posts':3,'forbidden':32,'failed_line':10000,'screenshots':0}
PHASES={'init','create','edit','delete','complete'}


def validate_stage(value,armed,*,complete=True):
    if (not isinstance(value,dict) or set(value)!=FLAGS|set(COUNTS)|{'result','phase'}
            or any(type(value[k]) is not bool for k in FLAGS)
            or any(type(value[k]) is not int or not 0<=value[k]<=limit for k,limit in COUNTS.items())
            or value['phase'] not in PHASES or value['result'] not in ('PASS','UNVERIFIED') or value['permit_writes'] is not armed):
        raise ValueError('native_trial/stage')
    if complete and (value['result']!='PASS' or value['phase']!='complete' or value['failed_line'] or value['forbidden']
            or not all(value[k] for k in FLAGS-{'permit_writes','local_pending_kept','dispatch_blocked','cache_verified'})
            or value['posts']!=(3 if armed else 0) or value['steps']!=(3 if armed else 0)
            or value['requests']<(16 if armed else 9)
            or value['cache_verified'] is not armed or value['dispatch_blocked'] is armed or value['local_pending_kept'] is armed):
        raise ValueError('native_trial/incomplete')
    return value


def read_reply(stream,timeout=100):
    # The initial payload is consumed before the peer can send its first reply.
    raw=b'';deadline=time.monotonic()+timeout
    with selectors.DefaultSelector() as selector:
        selector.register(stream,selectors.EVENT_READ)
        while time.monotonic()<deadline:
            if not selector.select(min(1,max(0,deadline-time.monotonic()))):continue
            byte=os.read(stream.fileno(),1)
            if not byte:raise ValueError('native_trial/peer_closed')
            raw+=byte
            if len(raw)>MAX_FRAME:raise ValueError('native_trial/reply_limit')
            if byte==b'\n':
                value=json.loads(raw)
                if not isinstance(value,dict):raise ValueError('native_trial/reply')
                return value
    raise TimeoutError('native_trial/peer_timeout')


def stop_reader(child):
    from process_loss_runtime import kill_reader_session,session_members
    if child.poll() is None:kill_reader_session(child)
    # An exited root can still leave a worker in another process group.
    for pid in session_members(child.pid):
        try:os.kill(pid,signal.SIGKILL)
        except ProcessLookupError:pass
    deadline=time.monotonic()+5
    while session_members(child.pid):
        for pid in session_members(child.pid):
            try:os.waitpid(pid,os.WNOHANG)
            except ChildProcessError:pass
        if time.monotonic()>deadline:raise RuntimeError('native_trial/workers')
        time.sleep(.01)
    child.wait()
    for stream in (child.stdin,child.stdout,child.stderr):
        if stream is not None:stream.close()


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',required=True,type=Path);parser.add_argument('--candidate',required=True,type=Path)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    parser.add_argument('--armed',action='store_true');parser.add_argument('--mock-port',type=int)
    args=parser.parse_args(argv);runtime=args.koreader.resolve()
    if sys.platform!='linux' or not (runtime/'luajit').is_file() or not 1<=min(args.width,args.height,args.dpi)<=max(args.width,args.height,args.dpi)<=4096:parser.error('Linux runtime and bounded dimensions required')
    if args.mock_port is not None and not 1<=args.mock_port<=65535:parser.error('invalid mock port')
    if not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines()):parser.error('tmpfs required')
    from process_loss_runtime import enable_subreaper
    enable_subreaper()
    def interrupt(_signum,_frame):raise RuntimeError('native_trial/interrupted')
    signal.signal(signal.SIGTERM,interrupt)
    report=dict(result='UNVERIFIED',profile_removed=False,installed_bytes_match=False,installed_files=0,stage=None)
    root,child,payload=None,None,None
    try:
        payload=read_initial(sys.stdin.buffer)
        if payload.get('permit_writes') is not args.armed or payload.get('mock_port')!=args.mock_port:raise ValueError('native_trial/scope')
        with tempfile.TemporaryDirectory(prefix='weread-native-thought-',dir='/dev/shm') as temporary:
            root=Path(temporary);profile=root/'profile';(profile/'plugins').mkdir(parents=True);(root/'xdg').mkdir(mode=0o700)
            extract_candidate(args.candidate,profile/'plugins')
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(root/'xdg'),EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi),WEREAD_NATIVE_THOUGHT_ARMED='1' if args.armed else '0')
            env.pop('WEREAD_NATIVE_THOUGHT_MOCK',None)
            if args.mock_port is not None:env['WEREAD_NATIVE_THOUGHT_MOCK']=str(args.mock_port)
            probe=Path(__file__).resolve().parent.parent/'spec/koreader/owner_thought_trial_probe.lua'
            child=subprocess.Popen([str(runtime/'luajit'),str(probe)],cwd=runtime,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
            try:
                write_initial(child.stdin,payload);frames=Frames(child.stdout,payload['rpc_token'])
                while True:
                    kind,value=frames.next()
                    if kind=='RESULT':
                        report['stage']=validate_stage(value,args.armed,complete=False);break
                    sys.stdout.buffer.write(b'\n'+frames.prefix+b'STEP='+json.dumps(value,separators=(',',':')).encode()+b'\n');sys.stdout.buffer.flush()
                    reply(child.stdin,read_reply(sys.stdin.buffer))
                if child.wait(timeout=10):raise ValueError('native_trial/child')
                validate_stage(report['stage'],args.armed)
            finally:stop_reader(child);child=None
            files=0
            with zipfile.ZipFile(args.candidate) as archive:
                for item in archive.infolist():
                    if item.is_dir():continue
                    actual=profile/'plugins'/item.filename
                    if actual.is_symlink() or actual.read_bytes()!=archive.read(item):raise ValueError('native_trial/package')
                    files+=1
            report.update(result='PASS',installed_bytes_match=True,installed_files=files)
    except Exception:pass
    finally:
        if child is not None:stop_reader(child)
        report['profile_removed']=root is not None and not root.exists()
    if payload is not None:
        # Validate the private token even on failure; never echo arbitrary input.
        import re
        token=payload.get('rpc_token')
        if isinstance(token,str) and re.fullmatch('[a-f0-9]{32}',token):
            sys.stdout.buffer.write(b'\nWEREAD_NATIVE_THOUGHT_'+token.encode()+b'_RESULT='+json.dumps(report,separators=(',',':')).encode()+b'\n');sys.stdout.buffer.flush()
    return int(report['result']!='PASS' or not report['profile_removed'])


if __name__=='__main__':raise SystemExit(main())
