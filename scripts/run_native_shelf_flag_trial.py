#!/usr/bin/env python3
"""Private native private-reading UI supervisor; no credentials on regular disk."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
from native_shelf_flag_trial import validate_plan,PROTOCOL
from native_trial_pipe import Frames,read_initial,reply,write_initial
from run_native_thought_trial import read_reply,stop_reader
from run_owner_reading_probe import check_installed
from run_persistent_ui_probe import extract_candidate
from secure_shelf_experiment import canonical
from verify_eink_renewal import validate_credentials

FLAGS={'anonymous_credentials','guard_selftest','native_detail','first_preview','second_preview','native_confirmations',
    'worker_heartbeat','cancel_no_post','local_state_preserved','cache_verified','journal_before_posts','workers_reaped','credential_audit'}
COUNTS={'native_gets':40,'native_posts':2,'denied':32,'screenshots':0,'failed_line':10000,'shelf_books':5000,'profile_files_audited':1024}
PHASES={'init','detail','preview','mark','restore','audit','complete'}


def validate_stage(value,armed):
    if (not isinstance(value,dict) or set(value)!=FLAGS|set(COUNTS)|{'result','phase','permit_writes'}
            or value['result'] not in ('PASS','UNVERIFIED') or value['phase'] not in PHASES
            or value['permit_writes'] is not armed or any(type(value[key]) is not bool for key in FLAGS)
            or any(type(value[key]) is not int or not 0<=value[key]<=cap for key,cap in COUNTS.items())):raise ValueError('native_shelf_flag/stage')
    if value['result']=='PASS':
        needed=FLAGS-{'second_preview','cache_verified','journal_before_posts'}
        if (value['phase']!='complete' or not all(value[key] for key in needed) or value['native_posts']!=(2 if armed else 0)
                or any(value[key] is not armed for key in ('second_preview','cache_verified','journal_before_posts'))
                or value['native_gets']<(13 if armed else 5) or value['denied'] or value['failed_line']
                or not value['shelf_books'] or not value['profile_files_audited']):raise ValueError('native_shelf_flag/incomplete')
    return value


def validate_payload(value,armed,mock_port):
    fields={'credentials','book_id','expected_metadata','shelf_books','mark','restore','permit_writes','rpc_token'}
    if mock_port is not None:fields.add('mock_port')
    if (not isinstance(value,dict) or set(value)!=fields or value['permit_writes'] is not armed
            or not isinstance(value['rpc_token'],str) or len(value['rpc_token'])!=32 or any(c not in 'abcdef0123456789' for c in value['rpc_token'])
            or type(value['shelf_books']) is not int or not 1<=value['shelf_books']<=5000
            or not isinstance(value['expected_metadata'],dict) or value['expected_metadata'].get('bookId')!=value['book_id']
            or value.get('mock_port')!=mock_port):raise ValueError('native_shelf_flag/input')
    grant=value['credentials'];validate_credentials(grant)
    validate_plan(dict(protocol=PROTOCOL,owner=grant['vid'],book_id=value['book_id'],groups_sha256='0'*64,
        grant_sha256=hashlib.sha256(canonical(grant)).hexdigest(),mark=value['mark'],restore=value['restore']))
    if mock_port is not None and (grant!=dict(vid='900000',accessToken='mock-native-access',refreshToken='mock-native-refresh',deviceId='eink334691225'+'1'*19)
                                 or value['book_id']!='900001'):raise ValueError('native_shelf_flag/mock')


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',required=True,type=Path);parser.add_argument('--candidate',required=True,type=Path)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    parser.add_argument('--armed',action='store_true');parser.add_argument('--mock-port',type=int);args=parser.parse_args();runtime=args.koreader.resolve()
    if sys.platform!='linux' or not (runtime/'luajit').is_file() or not 1<=min(args.width,args.height,args.dpi)<=max(args.width,args.height,args.dpi)<=4096:parser.error('bounded Linux runtime required')
    if args.mock_port is not None and not 1<=args.mock_port<=65535:parser.error('invalid loopback port')
    if not any(row.split()[1:3]==['/dev/shm','tmpfs'] for row in Path('/proc/mounts').read_text().splitlines()):parser.error('tmpfs required')
    from process_loss_runtime import enable_subreaper
    enable_subreaper()
    def interrupt(_signal,_frame):raise RuntimeError('native_shelf_flag/interrupted')
    signal.signal(signal.SIGTERM,interrupt)
    payload=root=child=None;result=dict(result='UNVERIFIED',profile_removed=False,installed=None,stage=None)
    try:
        payload=read_initial(sys.stdin.buffer)
        if len(json.dumps(payload).encode())>256*1024:raise ValueError('native_shelf_flag/input')
        validate_payload(payload,args.armed,args.mock_port)
        with tempfile.TemporaryDirectory(prefix='weread-private-trial-',dir='/dev/shm') as temporary:
            root=Path(temporary);profile=root/'profile';(profile/'plugins').mkdir(parents=True);(root/'xdg').mkdir(mode=0o700)
            extract_candidate(args.candidate,profile/'plugins')
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(root/'xdg'),EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi),WEREAD_PRIVATE_TRIAL_ARMED='1' if args.armed else '0')
            if args.mock_port is not None:env['WEREAD_PRIVATE_TRIAL_MOCK']=str(args.mock_port)
            probe=Path(__file__).resolve().parent.parent/'spec/koreader/owner_shelf_flag_trial_probe.lua'
            child=subprocess.Popen([str(runtime/'luajit'),str(probe)],env=env,cwd=runtime,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
            try:
                write_initial(child.stdin,payload);frames=Frames(child.stdout,payload['rpc_token'],timeout=210)
                while True:
                    kind,value=frames.next()
                    if kind=='RESULT':result['stage']=validate_stage(value,args.armed);break
                    sys.stdout.buffer.write(b'\n'+frames.prefix+b'STEP='+json.dumps(value,separators=(',',':')).encode()+b'\n');sys.stdout.buffer.flush()
                    reply(child.stdin,read_reply(sys.stdin.buffer))
                if child.wait(timeout=10) or result['stage']['result']!='PASS':raise ValueError('native_shelf_flag/child')
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
