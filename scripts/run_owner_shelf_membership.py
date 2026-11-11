#!/usr/bin/env python3
"""Disposable tmpfs runner; membership writes require both explicit arming gates."""
import argparse
import json
import os
import signal
from pathlib import Path
import subprocess
import sys
import tempfile

from owner_shelf_membership_contract import FRAME,ERRORS,decode_stage
from run_persistent_ui_probe import extract_candidate,run_child
from native_trial_pipe import Frames,read_initial,write_initial,reply
from run_native_thought_trial import read_reply,stop_reader
from run_owner_reading_probe import check_installed


def interactive(command,environment,payload,runtime):
    child=subprocess.Popen(command,env=environment,cwd=runtime,stdin=subprocess.PIPE,stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL,start_new_session=True)
    try:
        write_initial(child.stdin,payload);frames=Frames(child.stdout,payload['host_steps']['rpc_token'],timeout=180)
        while True:
            kind,value=frames.next()
            if kind=='RESULT':
                output=FRAME+json.dumps(value).encode();decode_stage(output,payload['permit_writes'])
                return child.wait(timeout=10),output,False
            sys.stdout.buffer.write(b'\n'+frames.prefix+b'STEP='+json.dumps(value,separators=(',',':')).encode()+b'\n')
            sys.stdout.buffer.flush();reply(child.stdin,read_reply(sys.stdin.buffer))
    finally:stop_reader(child)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True)
    parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600)
    parser.add_argument('--height',type=int,default=800)
    parser.add_argument('--dpi',type=int,default=167)
    parser.add_argument('--armed',action='store_true')
    parser.add_argument('--mock-port',type=int)
    parser.add_argument('--host-steps',action='store_true')
    args=parser.parse_args(argv);runtime=args.koreader.resolve()
    if sys.platform!='linux' or not (runtime/'luajit').is_file() or min(args.width,args.height,args.dpi)<1:parser.error('requires Linux and a built runtime')
    if args.mock_port is not None and not 1<=args.mock_port<=65535:parser.error('invalid mock port')
    if not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines()):parser.error('/dev/shm must be tmpfs')
    report=dict(result='UNVERIFIED',tmpfs_profile=True,profile_removed=False,runner_error='none',stage=None)
    root=private=None;payload=None;installed=None;token=''
    try:
        if args.host_steps:
            from process_loss_runtime import enable_subreaper
            enable_subreaper()
            def interrupt(_signal,_frame):raise RuntimeError('membership_interrupted')
            signal.signal(signal.SIGTERM,interrupt)
            payload=read_initial(sys.stdin.buffer);raw=json.dumps(payload).encode()
            host_steps=payload.get('host_steps')
            if not isinstance(host_steps,dict) or set(host_steps)!={'rpc_token'}:raise ValueError('input_limit')
            token=host_steps['rpc_token']
            if not isinstance(token,str) or len(token)!=32 or any(c not in 'abcdef0123456789' for c in token):raise ValueError('input_limit')
        else:raw=sys.stdin.buffer.read(256*1024+1)
        if len(raw)>256*1024:raise ValueError('input_limit')
        payload=json.loads(raw)
        if type(payload.get('permit_writes')) is not bool or payload['permit_writes'] is not args.armed:raise ValueError('input_limit')
        if payload.get('mock_port')!=args.mock_port:raise ValueError('input_limit')
        with tempfile.TemporaryDirectory(prefix='weread-membership-',dir='/dev/shm') as temporary:
            root=Path(temporary);profile=root/'profile';(profile/'plugins').mkdir(parents=True);(root/'xdg').mkdir(mode=0o700)
            extract_candidate(args.candidate,profile/'plugins')
            environment=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(root/'xdg'),
                EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',EMULATE_READER_W=str(args.width),
                EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi),WEREAD_MEMBERSHIP_ARMED='1' if args.armed else '0')
            if args.mock_port is not None:environment['WEREAD_MEMBERSHIP_MOCK']=str(args.mock_port)
            environment['WEREAD_MEMBERSHIP_HOST_STEPS']='1' if args.host_steps else '0'
            probe=Path(__file__).resolve().parent.parent/'spec/koreader/owner_shelf_membership_probe.lua'
            command=[str(runtime/'luajit'),str(probe)]
            if args.host_steps:code,out,repaint=interactive(command,environment,payload,runtime)
            else:code,out,repaint=run_child(command,environment,raw,runtime,timeout=150)
            envelope=decode_stage(out,args.armed);report['stage']=envelope['report'];private=envelope['private']
            if code or repaint or report['stage']['result']!='PASS':raise ValueError('stage_unverified')
            installed=check_installed(args.candidate,profile)
            report['result']='PASS'
    except subprocess.TimeoutExpired:report['runner_error']='child_timeout'
    except Exception as exc:report['runner_error']=str(exc) if str(exc) in ERRORS else 'runner_exception'
    finally:report['profile_removed']=root is not None and not root.exists()
    value=dict(report=report,private=private)
    if args.host_steps:
        if isinstance(token,str) and len(token)==32 and all(c in 'abcdef0123456789' for c in token):
            sys.stdout.buffer.write(b'\nWEREAD_NATIVE_THOUGHT_'+token.encode()+b'_RESULT='+json.dumps(dict(runner=value,installed=installed)).encode()+b'\n')
    else:sys.stdout.buffer.write(FRAME+json.dumps(value).encode()+b'\n')
    sys.stdout.buffer.flush()
    return 0 if report['result']=='PASS' and report['profile_removed'] else 1


if __name__=='__main__':raise SystemExit(main())
