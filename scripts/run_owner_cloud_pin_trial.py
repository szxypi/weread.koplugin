#!/usr/bin/env python3
"""Disposable native pin trial supervisor, with host gates after each POST."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
from native_trial_pipe import Frames,read_initial,reply,write_initial
from run_native_shelf_flag_trial import validate_stage
from run_native_thought_trial import read_reply,stop_reader
from run_owner_cloud_pin_preview import validate_payload as validate_preview
from run_owner_reading_probe import check_installed
from run_persistent_ui_probe import extract_candidate


def validate_payload(value,armed,mock_port=None,*,imported=False):
    if not isinstance(value,dict) or type(armed) is not bool or value.get('permit_writes') is not armed:
        raise ValueError('native_cloud_pin/input')
    original=dict(value);original['permit_writes']=False
    if mock_port is not None:original.pop('mock_port',None)
    validate_preview(original,allow_imported=imported)
    if mock_port is None:
        if 'mock_port' in value:raise ValueError('native_cloud_pin/input')
    elif (type(mock_port) is not int or not 1<=mock_port<=65535 or value.get('mock_port')!=mock_port
          or value['credentials']!=dict(vid='900000',accessToken='mock-native-access',refreshToken='mock-native-refresh',
                                        deviceId='eink334691225'+'1'*19)
          or value['book_id']!=('CB_SyntheticResume' if imported else '900001')):
        raise ValueError('native_cloud_pin/mock')
    return value


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',required=True,type=Path);parser.add_argument('--candidate',required=True,type=Path)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    parser.add_argument('--armed',action='store_true');parser.add_argument('--mock-port',type=int)
    parser.add_argument('--imported',action='store_true');args=parser.parse_args();runtime=args.koreader.resolve()
    if sys.platform!='linux' or not (runtime/'luajit').is_file() or not 1<=min(args.width,args.height,args.dpi)<=max(args.width,args.height,args.dpi)<=4096:parser.error('bounded Linux runtime required')
    if args.mock_port is not None and not 1<=args.mock_port<=65535:parser.error('invalid loopback port')
    if not any(row.split()[1:3]==['/dev/shm','tmpfs'] for row in Path('/proc/mounts').read_text().splitlines()):parser.error('tmpfs required')
    from process_loss_runtime import enable_subreaper
    enable_subreaper()
    def interrupt(_signal,_frame):raise RuntimeError('native_cloud_pin/interrupted')
    signal.signal(signal.SIGTERM,interrupt)
    payload=root=child=None;result=dict(result='UNVERIFIED',profile_removed=False,installed=None,stage=None)
    try:
        payload=validate_payload(read_initial(sys.stdin.buffer),args.armed,args.mock_port,imported=args.imported)
        if len(json.dumps(payload).encode())>256*1024:raise ValueError('native_cloud_pin/input')
        with tempfile.TemporaryDirectory(prefix='weread-cloud-pin-trial-',dir='/dev/shm') as temporary:
            root=Path(temporary);profile=root/'profile';(profile/'plugins').mkdir(parents=True);(root/'xdg').mkdir(mode=0o700)
            extract_candidate(args.candidate,profile/'plugins')
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(root/'xdg'),EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi),WEREAD_CLOUD_PIN_TRIAL_ARMED='1' if args.armed else '0')
            if args.mock_port is not None:env['WEREAD_CLOUD_PIN_TRIAL_MOCK']=str(args.mock_port)
            if args.imported:env['WEREAD_CLOUD_PIN_TRIAL_IMPORTED']='1'
            probe=Path(__file__).resolve().parent.parent/'spec/koreader/owner_cloud_pin_trial.lua'
            child=subprocess.Popen([str(runtime/'luajit'),str(probe)],env=env,cwd=runtime,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
            try:
                write_initial(child.stdin,payload);frames=Frames(child.stdout,payload['rpc_token'],timeout=210);steps=0
                while True:
                    kind,value=frames.next()
                    if kind=='RESULT':result['stage']=validate_stage(value,args.armed);break
                    if (not args.armed or set(value)!={'seq'} or type(value['seq']) is not int
                            or value['seq']!=steps+1 or steps>=2):raise ValueError('native_cloud_pin/step')
                    steps+=1
                    sys.stdout.buffer.write(b'\n'+frames.prefix+b'STEP='+json.dumps(value,separators=(',',':')).encode()+b'\n');sys.stdout.buffer.flush()
                    response=read_reply(sys.stdin.buffer)
                    if (set(response)!={'seq','ok'} or type(response['seq']) is not int
                            or response['seq']!=steps or response['ok'] is not True):raise ValueError('native_cloud_pin/rejected')
                    reply(child.stdin,response)
                if child.wait(timeout=10) or result['stage']['result']!='PASS' or steps!=(2 if args.armed else 0):raise ValueError('native_cloud_pin/child')
            finally:stop_reader(child);child=None
            result.update(result='PASS',installed=check_installed(args.candidate,profile))
    except Exception:pass
    finally:
        if child is not None:stop_reader(child)
        result['profile_removed']=root is not None and not root.exists()
    token=payload.get('rpc_token','') if isinstance(payload,dict) else ''
    if isinstance(token,str) and len(token)==32 and all(c in 'abcdef0123456789' for c in token):
        sys.stdout.buffer.write(b'\nWEREAD_NATIVE_THOUGHT_'+token.encode()+b'_RESULT='+json.dumps(result,separators=(',',':')).encode()+b'\n');sys.stdout.buffer.flush()
    return int(result['result']!='PASS' or not result['profile_removed'])


if __name__=='__main__':raise SystemExit(main())
