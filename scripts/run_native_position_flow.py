#!/usr/bin/env python3
"""Disposable tmpfs KOReader native worker supervisor; pipe-only private I/O."""
import argparse
import json
import os
from pathlib import Path
import resource
import signal
import subprocess
import sys
import tempfile
from native_position_flow_contract import validate_payload,validate_stage
from native_trial_pipe import Frames,read_initial,write_initial,reply
from run_native_thought_trial import read_reply,stop_reader
from run_owner_reading_probe import check_installed
from run_persistent_ui_probe import extract_candidate


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--koreader',required=True,type=Path);p.add_argument('--candidate',required=True,type=Path)
    p.add_argument('--width',type=int,default=600);p.add_argument('--height',type=int,default=800);p.add_argument('--dpi',type=int,default=167)
    p.add_argument('--armed',action='store_true');p.add_argument('--mock',action='store_true');a=p.parse_args();runtime=a.koreader.resolve()
    if sys.platform!='linux' or not (runtime/'luajit').is_file() or not 1<=min(a.width,a.height,a.dpi)<=max(a.width,a.height,a.dpi)<=4096:p.error('bounded Linux runtime required')
    if not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines()):p.error('tmpfs required')
    from process_loss_runtime import enable_subreaper
    enable_subreaper();resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    def interrupted(_signal,_frame):raise RuntimeError('native_position_flow/interrupted')
    signal.signal(signal.SIGTERM,interrupted)
    payload=root=child=None;result={'result':'UNVERIFIED','profile_removed':False,'installed':None,'stage':None}
    try:
        payload=read_initial(sys.stdin.buffer);validate_payload(payload,a.armed)
        if payload['mock'] is not a.mock or len(json.dumps(payload).encode())>256*1024:raise ValueError('native_position_flow/input')
        with tempfile.TemporaryDirectory(prefix='weread-native-position-flow-',dir='/dev/shm') as directory:
            root=Path(directory);profile=root/'profile';(profile/'plugins').mkdir(parents=True);(root/'xdg').mkdir(mode=0o700)
            extract_candidate(a.candidate,profile/'plugins')
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(root/'xdg'),EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                EMULATE_READER_W=str(a.width),EMULATE_READER_H=str(a.height),EMULATE_READER_DPI=str(a.dpi),WEREAD_POSITION_FLOW_ARMED='1' if a.armed else '0',WEREAD_POSITION_FLOW_MOCK='1' if a.mock else '0')
            probe=Path(__file__).resolve().parent.parent/'spec/koreader/native_position_service_probe.lua'
            child=subprocess.Popen([str(runtime/'luajit'),str(probe)],cwd=runtime,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
            try:
                write_initial(child.stdin,payload);frames=Frames(child.stdout,payload['rpc_token'],timeout=260)
                while True:
                    kind,value=frames.next()
                    if kind=='RESULT':result['stage']=validate_stage(value,a.armed);break
                    sys.stdout.buffer.write(b'\n'+frames.prefix+b'STEP='+json.dumps(value,separators=(',',':')).encode()+b'\n');sys.stdout.buffer.flush()
                    reply(child.stdin,read_reply(sys.stdin.buffer))
                if child.wait(timeout=10) or result['stage']['result']!='PASS':raise ValueError('native_position_flow/native')
            finally:stop_reader(child);child=None
            result.update(result='PASS',installed=check_installed(a.candidate,profile))
    except Exception:pass
    finally:
        if child is not None:stop_reader(child)
        result['profile_removed']=root is not None and not root.exists()
    token=payload.get('rpc_token','') if isinstance(payload,dict) else ''
    if isinstance(token,str) and len(token)==32 and all(c in 'abcdef0123456789' for c in token):
        sys.stdout.buffer.write(b'\nWEREAD_NATIVE_THOUGHT_'+token.encode()+b'_RESULT='+json.dumps(result,separators=(',',':')).encode()+b'\n');sys.stdout.buffer.flush()
    return int(result['result']!='PASS' or not result['profile_removed'])


if __name__=='__main__':raise SystemExit(main())
