#!/usr/bin/env python3
"""Private duplex runner for one native selection thought trial in tmpfs."""
import argparse
import json
import os
from pathlib import Path
import re
import resource
import signal
import subprocess
import sys
import tempfile

from native_trial_pipe import Frames,read_initial,reply,write_initial
from run_native_thought_trial import read_reply,stop_reader
from run_owner_reading_probe import check_installed
from run_persistent_ui_probe import extract_candidate,run_child
from run_native_direct_position_owner import synthetic_endpoint_allowed

REPO=Path(__file__).resolve().parent.parent


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--candidate',type=Path,required=True)
    modes=parser.add_mutually_exclusive_group()
    modes.add_argument('--highlight',action='store_true',help='Run the bounded highlight lifecycle')
    modes.add_argument('--bookmark',action='store_true',help='Run the bounded bookmark lifecycle')
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    args=parser.parse_args(argv);runtime=args.koreader.resolve()
    if (sys.platform!='linux' or not (runtime/'luajit').is_file() or not all(1<=n<=4096 for n in (args.width,args.height,args.dpi))
            or not any(row.split()[1:3]==['/dev/shm','tmpfs'] for row in Path('/proc/mounts').read_text().splitlines())):
        parser.error('Linux, KOReader and tmpfs required')
    from process_loss_runtime import enable_subreaper
    enable_subreaper();resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    def interrupted(_signal,_frame):raise RuntimeError('direct_ui_trial/interrupted')
    signal.signal(signal.SIGTERM,interrupted)
    payload=root=child=None
    result=dict(result='UNVERIFIED',profile_removed=False,installed_bytes_match=False,credential_file_audit=False,steps=0,posts=0,blocked=False,phase='input',probe_line=0,outcome='none',readbacks=0,diagnostic='none')
    try:
        payload=read_initial(sys.stdin.buffer);trial=payload['trial'];token=trial['rpc_token']
        endpoint=payload.get('mock_endpoint')
        match=re.fullmatch(r'http://127\.0\.0\.1:([1-9][0-9]{0,4})',endpoint) if isinstance(endpoint,str) else None
        if (not isinstance(token,str) or not re.fullmatch('[a-f0-9]{32}',token) or type(trial['armed']) is not bool
                or (trial.get('bookmark') is True)!=args.bookmark or 'bookmark' in trial and trial['bookmark'] is not True
                or 'plain_text' in payload and (payload['plain_text'] is not True or not (args.bookmark or args.highlight)
                    or type(payload.get('book_version')) is not int or payload['book_version']!=0
                    or type(payload.get('chapter_idx')) is not int or not 0<=payload['chapter_idx']<=1000000
                    or type(payload.get('source_bytes')) is not int or not 0<payload['source_bytes']<=2*1024*1024)
                or 'cross_check' in trial and (trial['cross_check'] is not True or not args.bookmark or not trial['armed'])
                or endpoint is not None and (not match or int(match.group(1))>65535)
                or not synthetic_endpoint_allowed(payload,endpoint)):
            raise ValueError('direct_ui_trial/input')
        with tempfile.TemporaryDirectory(prefix='weread-native-ui-trial-',dir='/dev/shm') as directory:
            root=Path(directory);profile=root/'profile';xdg=root/'xdg'
            (profile/'plugins').mkdir(parents=True);xdg.mkdir(mode=0o700)
            extract_candidate(args.candidate,profile/'plugins');plugin=profile/'plugins/weread.koplugin'
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(xdg),LD_LIBRARY_PATH=str(runtime/'libs'),
                SDL_VIDEODRIVER='dummy',EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi),
                WEREAD_DIRECT_OWNER_TMPFS='1')
            result['phase']='prepare';raw=json.dumps(payload,ensure_ascii=False,separators=(',',':')).encode()
            code,out,repaint=run_child([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_owner_error_guard.lua'),
                str(plugin),str(REPO/'spec/koreader/native_direct_owner_ui_probe.lua')],env,raw,runtime,timeout=180)
            lines=[line for line in out.splitlines() if line.startswith(b'WEREAD_DIRECT_OWNER=')]
            if code or repaint or len(lines)!=1:raise ValueError('direct_ui_trial/prepare')
            prepared=json.loads(lines[0].split(b'=',1)[1]);path=Path(prepared['path'])
            if not prepared.get('ok') or not prepared.get('source_matches') or not path.is_file() or profile not in path.parents:
                raise ValueError('direct_ui_trial/prepare')
            result['phase']='reader';private=dict(payload,path=str(path))
            child=subprocess.Popen([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_owner_error_guard.lua'),
                str(plugin),str(REPO/'spec/koreader'/('native_direct_highlight_trial_probe.lua' if args.highlight or args.bookmark else 'native_direct_selection_trial_probe.lua')),
                str(REPO/'spec/koreader'/('native_highlight_trial_gate.lua' if args.highlight or args.bookmark else 'native_thought_trial_gate.lua'))],cwd=runtime,env=env,
                stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
            try:
                write_initial(child.stdin,private);frames=Frames(child.stdout,token,timeout=900 if trial.get('cross_check') else 360)
                while True:
                    kind,value=frames.next()
                    if kind=='RESULT':
                        if value.get('result')=='UNVERIFIED' and type(value.get('failed_line')) is int:
                            result['probe_line']=value['failed_line']
                            if value.get('outcome') in ('confirmed','unconfirmed','unavailable','login','noop'):result['outcome']=value['outcome']
                            if type(value.get('readbacks')) is int and 0<=value['readbacks']<=4:result['readbacks']=value['readbacks']
                            diagnostic=profile/'trial-diagnostic'
                            if diagnostic.is_file() and diagnostic.stat().st_size<=1024:
                                lines=diagnostic.read_text().splitlines()
                                if lines and re.fullmatch(r'(?:snapshot_[a-z_]+|point_[a-z_]+|shelf_error|shelf_changed|auth_[a-z_]+)',lines[-1]):result['diagnostic']=lines[-1]
                            raise ValueError('direct_ui_trial/probe')
                        if (set(value)!={'result','steps','posts','blocked'} or value['result']!='PASS'
                                or type(value['steps']) is not int or type(value['posts']) is not int or type(value['blocked']) is not bool):
                            raise ValueError('direct_ui_trial/stage')
                        result.update({key:value[key] for key in ('steps','posts','blocked')});break
                    sys.stdout.buffer.write(b'\n'+frames.prefix+b'STEP='+json.dumps(value,separators=(',',':')).encode()+b'\n')
                    sys.stdout.buffer.flush();reply(child.stdin,read_reply(sys.stdin.buffer,timeout=720 if trial.get('cross_check') else 100))
                if child.wait(timeout=15):raise ValueError('direct_ui_trial/child')
            finally:stop_reader(child);child=None
            result['phase']='audit';grant=payload['credentials'];secrets=[grant[key] for key in ('accessToken','refreshToken','deviceId')]
            secrets.extend(value for key,value in payload['web_cookies'].items() if key!='wr_vid' and isinstance(value,str) and len(value)>=8)
            for item in root.rglob('*'):
                if item.is_symlink():raise ValueError('direct_ui_trial/symlink')
                if item.is_file() and plugin not in item.parents:
                    if item.stat().st_size>128*1024*1024:raise ValueError('direct_ui_trial/file_limit')
                    if any(value.encode() in item.read_bytes() for value in secrets):raise ValueError('direct_ui_trial/credential_file')
            installed=check_installed(args.candidate,profile)
            result.update(result='PASS',phase='complete',installed_bytes_match=installed['bytes_match'],credential_file_audit=True)
    except (Exception,KeyboardInterrupt):pass
    finally:
        if child is not None:stop_reader(child)
        result['profile_removed']=root is not None and not root.exists()
    if payload is not None:
        token=payload.get('trial',{}).get('rpc_token','')
        if isinstance(token,str) and re.fullmatch('[a-f0-9]{32}',token):
            sys.stdout.buffer.write(b'\nWEREAD_NATIVE_THOUGHT_'+token.encode()+b'_RESULT='+json.dumps(result,separators=(',',':')).encode()+b'\n');sys.stdout.buffer.flush()
    return int(result['result']!='PASS' or not result['profile_removed'])


if __name__=='__main__':raise SystemExit(main())
