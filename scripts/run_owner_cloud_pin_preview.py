#!/usr/bin/env python3
"""Disposable KOReader preview; all account writes are blocked in the child."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
from cloud_pin_contract import valid_metadata
from native_trial_pipe import Frames,read_initial,write_initial
from run_native_shelf_flag_trial import validate_stage
from run_native_thought_trial import stop_reader
from run_owner_reading_probe import check_installed
from run_persistent_ui_probe import extract_candidate
from verify_eink_renewal import validate_credentials


def validate_payload(value):
    fields={'credentials','book_id','expected_metadata','shelf_books','mark','restore','permit_writes','rpc_token'}
    if (not isinstance(value,dict) or set(value)!=fields or value['permit_writes'] is not False
            or not isinstance(value['rpc_token'],str) or len(value['rpc_token'])!=32
            or any(c not in 'abcdef0123456789' for c in value['rpc_token'])
            or type(value['shelf_books']) is not int or not 1<=value['shelf_books']<=5000
            or not isinstance(value['expected_metadata'],dict) or value['expected_metadata'].get('bookId')!=value['book_id']):
        raise ValueError('cloud_pin_preview/input')
    validate_credentials(value['credentials']);mark,restore=value['mark'],value['restore']
    if (not valid_metadata(mark) or not valid_metadata(restore) or mark['book_id']!=value['book_id']
            or restore['book_id']!=value['book_id'] or mark['desired'] is not True or restore['desired'] is not False
            or mark['before'] not in ('missing',False) or restore['before'] is not True
            or mark['after_hash']!=restore['before_hash'] or mark['before_hash'] not in (restore['after_hash'],restore['alternate_hash'])
            or mark['position_hash']!=restore['position_hash']):raise ValueError('cloud_pin_preview/plan')
    return value


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',required=True,type=Path);parser.add_argument('--candidate',required=True,type=Path)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    args=parser.parse_args();runtime=args.koreader.resolve()
    if sys.platform!='linux' or not (runtime/'luajit').is_file() or not 1<=min(args.width,args.height,args.dpi)<=max(args.width,args.height,args.dpi)<=4096:parser.error('bounded Linux runtime required')
    if not any(row.split()[1:3]==['/dev/shm','tmpfs'] for row in Path('/proc/mounts').read_text().splitlines()):parser.error('tmpfs required')
    from process_loss_runtime import enable_subreaper
    enable_subreaper()
    def interrupt(_signal,_frame):raise RuntimeError('cloud_pin_preview/interrupted')
    signal.signal(signal.SIGTERM,interrupt)
    payload=root=child=None;result=dict(result='UNVERIFIED',profile_removed=False,installed=None,stage=None)
    try:
        payload=validate_payload(read_initial(sys.stdin.buffer))
        if len(json.dumps(payload).encode())>256*1024:raise ValueError('cloud_pin_preview/input')
        with tempfile.TemporaryDirectory(prefix='weread-cloud-pin-preview-',dir='/dev/shm') as temporary:
            root=Path(temporary);profile=root/'profile';(profile/'plugins').mkdir(parents=True);(root/'xdg').mkdir(mode=0o700)
            extract_candidate(args.candidate,profile/'plugins')
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(root/'xdg'),EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi),WEREAD_CLOUD_PIN_PREVIEW_ARMED='0')
            probe=Path(__file__).resolve().parent.parent/'spec/koreader/owner_cloud_pin_preview.lua'
            child=subprocess.Popen([str(runtime/'luajit'),str(probe)],env=env,cwd=runtime,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
            try:
                write_initial(child.stdin,payload);frames=Frames(child.stdout,payload['rpc_token'],timeout=210)
                kind,value=frames.next()
                if kind!='RESULT':raise ValueError('cloud_pin_preview/unexpected_step')
                result['stage']=validate_stage(value,False)
                if child.wait(timeout=10) or result['stage']['result']!='PASS':raise ValueError('cloud_pin_preview/child')
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
