#!/usr/bin/env python3
"""Duplex, disposable native-chapter time trial; broker grants every step."""
import argparse
import json
import os
from pathlib import Path
import re
import resource
import subprocess
import sys
import tempfile

from native_trial_pipe import Frames, read_initial, reply, stop, write_initial
from run_native_direct_position_owner import frame, synthetic_endpoint_allowed
from run_persistent_ui_probe import extract_candidate, run_child
from verify_eink_renewal import validate_credentials
from verify_owner_reading import validate_cookies

REPO=Path(__file__).resolve().parent.parent


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',required=True,type=Path);parser.add_argument('--candidate',required=True,type=Path)
    parser.add_argument('--width',type=int,default=1264);parser.add_argument('--height',type=int,default=1680)
    parser.add_argument('--dpi',type=int,default=300);parser.add_argument('--armed',action='store_true')
    parser.add_argument('--automatic',action='store_true')
    args=parser.parse_args(argv);runtime=args.koreader.resolve()
    if (sys.platform!='linux' or not (runtime/'luajit').is_file() or not args.candidate.is_file()
            or not all(1<=value<=4096 for value in (args.width,args.height,args.dpi))
            or not any(row.split()[1:3]==['/dev/shm','tmpfs'] for row in Path('/proc/mounts').read_text().splitlines())):
        parser.error('isolated Linux KOReader and tmpfs required')
    from process_loss_runtime import enable_subreaper
    enable_subreaper();resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    payload=root=child=None;token=None;result='UNVERIFIED';stage='input';clean=False;diagnostic=None
    try:
        payload=read_initial(sys.stdin.buffer);token=payload.get('token')
        if (not isinstance(token,str) or not re.fullmatch('[a-f0-9]{32}',token)
                or type(payload.get('armed')) is not bool or payload['armed'] is not args.armed
                or payload.get('automatic',False) is not args.automatic
                or not synthetic_endpoint_allowed(payload,payload.get('mock_endpoint'))):raise ValueError('input')
        grant=payload['credentials'];validate_credentials(grant);validate_cookies(payload['web_cookies'],grant['vid'])
        if not isinstance(payload.get('months'),list) or not 1<=len(payload['months'])<=2:
            raise ValueError('months')
        with tempfile.TemporaryDirectory(prefix='weread-direct-time-trial-',dir='/dev/shm') as directory:
            root=Path(directory);profile=root/'profile';plugins=profile/'plugins';plugins.mkdir(parents=True)
            xdg=root/'xdg';xdg.mkdir(mode=0o700);extract_candidate(args.candidate,plugins)
            plugin=plugins/'weread.koplugin'
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(xdg),LD_LIBRARY_PATH=str(runtime/'libs'),TZ='Asia/Shanghai',
                SDL_VIDEODRIVER='dummy',EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi),
                WEREAD_DIRECT_OWNER_TMPFS='1')
            stage='prepare'
            code,out,repaint=run_child([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_owner_error_guard.lua'),
                str(plugin),str(REPO/'spec/koreader/native_direct_home_full_owner_probe.lua')],env,
                json.dumps(dict(payload,plugin_home=True,quick_search=False),ensure_ascii=False).encode(),runtime,timeout=180)
            prepared=frame(out,b'WEREAD_DIRECT_HOME_FULL=');path=Path(prepared.get('path',''))
            if (code or repaint or prepared.get('ok') is not True or prepared.get('source_matches') is not True
                    or not path.is_file() or profile/'weread' not in path.parents):raise ValueError('prepare')
            stage='capture'
            code,out,repaint=run_child([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_owner_error_guard.lua'),
                str(REPO),str(REPO/'spec/koreader/native_direct_time_owner_probe.lua')],env,
                json.dumps(dict(stage='capture',path=str(path),book_id=payload['book_id'],vid=grant['vid'])).encode(),runtime,timeout=150)
            captured=frame(out,b'WEREAD_DIRECT_TIME_OWNER=')
            if (code or repaint or captured.get('ok') is not True or captured.get('network_blocked') is not True
                    or type(captured.get('seconds')) is not int or not 5<=captured['seconds']<=20
                    or not isinstance(captured.get('snapshot'),str) or not re.fullmatch('[a-f0-9]{64}',captured['snapshot'])):
                raise ValueError('capture')
            private=dict(token=token,armed=args.armed,path=str(path),book_id=payload['book_id'],chapter_uid=payload['uid'],
                book_version=payload['book_version'],credentials=grant,cookies=payload['web_cookies'],months=payload['months'],
                ledger_hash=captured['snapshot'])
            if args.automatic:private['automatic']=True
            if payload.get('mock_endpoint') is not None:private['mock_endpoint']=payload['mock_endpoint']
            def emit(kind,value):
                raw=json.dumps(value,separators=(',',':')).encode()
                if len(raw)>65536:raise ValueError('frame_limit')
                sys.stdout.buffer.write(b'\nWEREAD_NATIVE_THOUGHT_'+token.encode()+b'_'+kind.encode()+b'='+raw+b'\n');sys.stdout.buffer.flush()
            stage='ready';emit('STEP',dict(kind='ready',seconds=captured['seconds']))
            answer=json.loads(sys.stdin.buffer.readline(65537))
            if answer!=dict(kind='ready',ok=True):raise ValueError('ready')
            stage='ui';child=subprocess.Popen([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_time_trial_ui.lua'),str(REPO)],
                cwd=runtime,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
            write_initial(child.stdin,private);frames=Frames(child.stdout,token,timeout=300,max_frame=65536)
            seen=[];reported=None
            while True:
                kind,event=frames.next()
                if kind=='RESULT':reported=event;break
                name=event.get('kind')
                if name not in ('selection','claim','ack') or name in seen or name!='selection' and not seen:
                    raise ValueError('event_order')
                if name=='ack' and (not args.armed or seen!=['selection','claim']):raise ValueError('event_order')
                if name=='claim' and seen!=['selection']:raise ValueError('event_order')
                seen.append(name);emit('STEP',event)
                answer=json.loads(sys.stdin.buffer.readline(65537))
                if set(answer)!={'kind','ok'} or answer['kind']!=name or type(answer['ok']) is not bool:
                    raise ValueError('reply')
                if name=='claim' and not args.armed and answer['ok']:raise ValueError('dry_grant')
                reply(child.stdin,answer)
            if payload.get('mock_endpoint') and isinstance(reported,dict):
                diagnostic={key:reported.get(key) for key in ('result','failed_module','failed_line','guard_failure','guard_stage') if key in reported}
                diagnostic['events']=list(seen)
            if (child.wait(timeout=15)!=0 or reported!={'result':'PASS',
                    'automatic' if args.automatic else 'native_menu':True,'background_service':True,
                    'local_phase':'none' if args.armed else 'claimed','workers_reaped':True}
                    or seen!=(['selection','claim','ack'] if args.armed else ['selection','claim'])):
                raise ValueError('ui')
            stop(child);child=None
            stage='audit'
            secrets=[grant[key].encode() for key in ('accessToken','refreshToken','deviceId')]
            secrets.extend(value.encode() for key,value in payload['web_cookies'].items() if key!='wr_vid' and len(value)>=8)
            for item in profile.rglob('*'):
                if item.is_symlink():raise ValueError('symlink')
                if item.is_file() and plugin not in item.parents:
                    if item.stat().st_size>128*1024*1024:raise ValueError('file_size')
                    if any(secret in item.read_bytes() for secret in secrets):raise ValueError('credential_file')
            from run_owner_reading_probe import check_installed
            if check_installed(args.candidate,profile).get('bytes_match') is not True:raise ValueError('installed')
            result='ACKNOWLEDGED' if args.armed else 'DRY_BLOCKED'
            diagnostic=None
        clean=not root.exists()
    except (Exception,KeyboardInterrupt):
        result='UNVERIFIED'
    finally:
        if child is not None:stop(child)
        if root is not None and not root.exists():clean=True
        if isinstance(token,str) and re.fullmatch('[a-f0-9]{32}',token):
            value=dict(result=result,profile_removed=clean,stage=stage)
            if diagnostic is not None:value['diagnostic']=diagnostic
            sys.stdout.buffer.write(b'\nWEREAD_NATIVE_THOUGHT_'+token.encode()+b'_RESULT='+json.dumps(value).encode()+b'\n');sys.stdout.buffer.flush()
    return int(result not in ('ACKNOWLEDGED','DRY_BLOCKED') or not clean)


if __name__=='__main__':raise SystemExit(main())
