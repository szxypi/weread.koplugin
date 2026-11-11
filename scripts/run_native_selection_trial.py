#!/usr/bin/env python3
"""Private duplex supervisor for one new-selection native trial; no credentials on disk."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile

from native_trial_pipe import Frames,read_initial,reply,write_initial
from owner_selection_preview import validate_input
from run_native_thought_trial import read_reply,stop_reader
from run_owner_reading_probe import check_installed
from run_persistent_ui_probe import extract_candidate
from verify_owner_reading import validate_cookies,validate_stage as validate_reading

FLAGS={'permit_writes','source_reference','native_controls','exact_creation_body','cache_verified','local_pending_kept','dispatch_blocked','heartbeat'}
COUNTS={'steps':3,'native_gets':32,'native_posts':3,'blocked_posts':1,'native_denied':32,'failed_line':10000}


def validate_stage(stage,armed,complete=True):
    if not isinstance(stage,dict):raise ValueError('selection_trial/stage')
    addon=stage.get('selection_trial')
    if (not isinstance(addon,dict) or set(addon)!=FLAGS|set(COUNTS)|{'phase'}
            or any(type(addon[k]) is not bool for k in FLAGS) or addon['permit_writes'] is not armed
            or any(type(addon[k]) is not int or not 0<=addon[k]<=cap for k,cap in COUNTS.items())
            or addon['phase'] not in ('init','create','edit','delete','complete')):raise ValueError('selection_trial/stage')
    basic={k:v for k,v in stage.items() if k!='selection_trial'}
    validate_reading(basic,'live',selection_preview=True)
    if complete and (stage['result']!='PASS' or addon['phase']!='complete' or addon['native_denied'] or addon['failed_line']
            or not all(addon[k] for k in ('source_reference','native_controls','exact_creation_body','heartbeat'))
            or addon['steps']!=(3 if armed else 0) or addon['native_posts']!=(3 if armed else 0)
            or addon['blocked_posts']!=(0 if armed else 1) or addon['cache_verified'] is not armed
            or addon['native_gets']<(11 if armed else 4)
            or addon['local_pending_kept'] is armed or addon['dispatch_blocked'] is armed):raise ValueError('selection_trial/incomplete')
    return stage


def validate_payload(payload,armed,mock_port):
    fields={'book_id','chapter_uid','source_text','shelf_ids','shelf_books','source_format','source_raw_sha256','source_sample_offset',
            'vid','cookies','selection_preview','selection_trial'}
    if mock_port is not None:fields.add('selection_mock_port')
    if not isinstance(payload,dict) or set(payload)!=fields:raise ValueError('selection_trial/input')
    from my_cloud_marks_model import identifier,integer
    if (not isinstance(payload['source_text'],str) or not 32<=len(payload['source_text'].encode())<=128
            or not integer(payload['source_sample_offset'],16*1024*1024)
            or not integer(payload['shelf_books'],5000) or not payload['shelf_books']
            or not isinstance(payload['shelf_ids'],list) or not 1<=len(payload['shelf_ids'])<=5000
            or any(not identifier(key) for key in payload['shelf_ids']) or payload['book_id'] not in payload['shelf_ids']):raise ValueError('selection_trial/input')
    validate_input(payload);trial=payload.get('selection_trial')
    if (not isinstance(trial,dict) or set(trial)!={'armed','rpc_token','original_ids','edited_text'} or trial['armed'] is not armed
            or not isinstance(trial['rpc_token'],str) or len(trial['rpc_token'])!=32
            or any(c not in '0123456789abcdef' for c in trial['rpc_token'])
            or not isinstance(trial['original_ids'],list) or len(trial['original_ids'])>18
            or len(json.dumps(payload['cookies']).encode())>4096 or payload.get('selection_mock_port')!=mock_port):raise ValueError('selection_trial/input')
    from annotation_experiment_model import valid_key,note_text
    if any(not valid_key(key) for key in trial['original_ids']) or len(set(trial['original_ids']))!=len(trial['original_ids']):raise ValueError('selection_trial/input')
    content=payload['selection_preview']['body']['content'];nonce=content.removeprefix('KOReader 私密想法验证 ').removesuffix(' 初始内容')
    if content!=note_text(nonce) or trial['edited_text']!=note_text(nonce,True):raise ValueError('selection_trial/input')
    if mock_port is not None:
        cfg=payload['selection_preview']
        if (payload['vid']!='900000' or payload['book_id']!='900001' or payload['cookies']!={'wr_vid':'900000','wr_skey':'mock_key'}
                or cfg['credentials']['accessToken']!='mock-native-access' or cfg['credentials']['refreshToken']!='mock-native-refresh'):raise ValueError('selection_trial/mock')


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',required=True,type=Path);parser.add_argument('--candidate',required=True,type=Path)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    parser.add_argument('--armed',action='store_true');parser.add_argument('--mock-port',type=int)
    feature=parser.add_mutually_exclusive_group()
    feature.add_argument('--highlights',action='store_true');feature.add_argument('--highlight-styles',action='store_true');feature.add_argument('--bookmarks',action='store_true')
    args=parser.parse_args(argv)
    check_payload,check_stage=validate_payload,validate_stage
    if args.highlights or args.highlight_styles:
        from native_highlight_trial import validate_payload as check_payload,validate_stage as check_stage
        if args.highlight_styles:
            from functools import partial
            check_payload,check_stage=partial(check_payload,styles=True),partial(check_stage,styles=True)
    elif args.bookmarks:
        from native_bookmark_trial import validate_payload as check_payload,validate_stage as check_stage
    runtime=args.koreader.resolve()
    if sys.platform!='linux' or not (runtime/'luajit').is_file() or not 1<=min(args.width,args.height,args.dpi)<=max(args.width,args.height,args.dpi)<=4096:parser.error('bounded Linux runtime required')
    if args.mock_port is not None and not 1<=args.mock_port<=65535:parser.error('invalid loopback port')
    if not any(row.split()[1:3]==['/dev/shm','tmpfs'] for row in Path('/proc/mounts').read_text().splitlines()):parser.error('tmpfs required')
    from process_loss_runtime import enable_subreaper
    enable_subreaper()
    def interrupt(_signal,_frame):raise RuntimeError('selection_trial/interrupted')
    signal.signal(signal.SIGTERM,interrupt)
    payload=None;root=child=None
    result=dict(result='UNVERIFIED',profile_removed=False,installed_files=0,installed_bytes_match=False,stage=None,cookies={})
    try:
        payload=read_initial(sys.stdin.buffer);check_payload(payload,args.armed,args.mock_port)
        with tempfile.TemporaryDirectory(prefix='weread-reading-',dir='/dev/shm') as temporary:
            root=Path(temporary);profile=root/'profile';(profile/'plugins').mkdir(parents=True);(root/'xdg').mkdir(mode=0o700)
            extract_candidate(args.candidate,profile/'plugins')
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(root/'xdg'),EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi),WEREAD_SELECTION_ARMED='1' if args.armed else '0')
            case=Path(__file__).resolve().parent.parent/'spec/koreader'/('owner_bookmark_trial_case.lua' if args.bookmarks
                else 'owner_highlight_trial_case.lua' if args.highlights or args.highlight_styles else 'owner_selection_trial_case.lua')
            child=subprocess.Popen([str(runtime/'luajit'),str(case.with_name('owner_reading_probe.lua')),'selection-trial',str(case)],cwd=runtime,
                env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
            try:
                write_initial(child.stdin,payload);frames=Frames(child.stdout,payload['selection_trial']['rpc_token'],timeout=360)
                while True:
                    kind,value=frames.next()
                    if kind=='RESULT':
                        if set(value)!={'report','cookies'}:raise ValueError('selection_trial/frame')
                        result['stage']=check_stage(value['report'],args.armed,False);result['cookies']=validate_cookies(value['cookies'],payload['vid']);break
                    sys.stdout.buffer.write(b'\n'+frames.prefix+b'STEP='+json.dumps(value,separators=(',',':')).encode()+b'\n');sys.stdout.buffer.flush()
                    reply(child.stdin,read_reply(sys.stdin.buffer))
                if child.wait(timeout=10):raise ValueError('selection_trial/child')
                check_stage(result['stage'],args.armed)
            finally:stop_reader(child);child=None
            installed=check_installed(args.candidate,profile)
            result.update(result='PASS',installed_files=installed['files'],installed_bytes_match=True)
    except Exception:pass
    finally:
        if child is not None:stop_reader(child)
        result['profile_removed']=root is not None and not root.exists()
    if payload is not None:
        token=payload.get('selection_trial',{}).get('rpc_token','')
        if isinstance(token,str) and len(token)==32 and all(c in '0123456789abcdef' for c in token):
            sys.stdout.buffer.write(b'\nWEREAD_NATIVE_THOUGHT_'+token.encode()+b'_RESULT='+json.dumps(result,separators=(',',':')).encode()+b'\n');sys.stdout.buffer.flush()
    return int(result['result']!='PASS' or not result['profile_removed'])


if __name__=='__main__':raise SystemExit(main())
