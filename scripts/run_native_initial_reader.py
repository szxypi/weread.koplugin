#!/usr/bin/env python3
"""Private duplex ReaderUI trial supervisor; credentials remain in memory/tmpfs."""
import argparse
import json
import os
from pathlib import Path
import resource
import signal
import subprocess
import sys
import tempfile
from native_trial_pipe import Frames,read_initial,write_initial,reply
from native_initial_reader_contract import validate_payload,validate_stage
from run_native_thought_trial import read_reply,stop_reader
from run_owner_reading_probe import check_installed
from run_persistent_ui_probe import extract_candidate
from verify_owner_reading import validate_cookies


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--koreader',required=True,type=Path);p.add_argument('--candidate',required=True,type=Path)
    p.add_argument('--width',type=int,default=600);p.add_argument('--height',type=int,default=800);p.add_argument('--dpi',type=int,default=167)
    p.add_argument('--armed',action='store_true');p.add_argument('--mock-port',type=int);a=p.parse_args(argv);runtime=a.koreader.resolve()
    if (sys.platform!='linux' or not (runtime/'luajit').is_file()
            or not all(1<=n<=4096 for n in (a.width,a.height,a.dpi))):p.error('bounded Linux runtime required')
    if not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines()):p.error('tmpfs required')
    from process_loss_runtime import enable_subreaper
    enable_subreaper();resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    def interrupted(_signal,_frame):raise RuntimeError('initial_reader/interrupted')
    signal.signal(signal.SIGTERM,interrupted)
    payload=root=child=None;result=dict(result='UNVERIFIED',profile_removed=False,installed=None,stage=None,cookies={})
    try:
        payload=read_initial(sys.stdin.buffer);validate_payload(payload,a.armed,a.mock_port);result['cookies']=payload['cookies']
        with tempfile.TemporaryDirectory(prefix='weread-reading-',dir='/dev/shm') as directory:
            root=Path(directory);profile=root/'profile';(profile/'plugins').mkdir(parents=True);(root/'xdg').mkdir(mode=0o700)
            extract_candidate(a.candidate,profile/'plugins')
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(root/'xdg'),EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                     EMULATE_READER_W=str(a.width),EMULATE_READER_H=str(a.height),EMULATE_READER_DPI=str(a.dpi),WEREAD_NATIVE_INITIAL_READER_ARMED='1' if a.armed else '0')
            folder=Path(__file__).resolve().parent.parent/'spec/koreader'
            child=subprocess.Popen([str(runtime/'luajit'),str(folder/'owner_reading_probe.lua'),'native-initial-reader',str(folder/'owner_native_initial_reader_case.lua')],
                                   cwd=runtime,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
            try:
                write_initial(child.stdin,payload);frames=Frames(child.stdout,payload['native_initial_reader']['rpc_token'],timeout=360)
                while True:
                    kind,value=frames.next()
                    if kind=='RESULT':
                        if set(value)!={'report','cookies'}:raise ValueError('initial_reader/frame')
                        result['stage']=validate_stage(value['report'],a.armed,complete=False)
                        result['cookies']=validate_cookies(value['cookies'],payload['vid']);break
                    sys.stdout.buffer.write(b'\n'+frames.prefix+b'STEP='+json.dumps(value,separators=(',',':')).encode()+b'\n');sys.stdout.buffer.flush()
                    reply(child.stdin,read_reply(sys.stdin.buffer))
                if child.wait(timeout=15):raise ValueError('initial_reader/child')
                validate_stage(result['stage'],a.armed)
            finally:stop_reader(child);child=None
            result.update(result='PASS',installed=check_installed(a.candidate,profile))
    except Exception:pass
    finally:
        if child is not None:stop_reader(child)
        result['profile_removed']=root is not None and not root.exists()
    if payload is not None:
        token=payload.get('native_initial_reader',{}).get('rpc_token','')
        if isinstance(token,str) and len(token)==32 and all(c in 'abcdef0123456789' for c in token):
            sys.stdout.buffer.write(b'\nWEREAD_NATIVE_THOUGHT_'+token.encode()+b'_RESULT='+json.dumps(result,separators=(',',':')).encode()+b'\n');sys.stdout.buffer.flush()
    return int(result['result']!='PASS' or not result['profile_removed'])


if __name__=='__main__':raise SystemExit(main())
