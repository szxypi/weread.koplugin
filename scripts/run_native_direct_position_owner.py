#!/usr/bin/env python3
"""Private, read-only native reader position probe in an isolated tmpfs profile."""
import argparse
import json
import os
import re
from pathlib import Path
import sys
import tempfile
import zipfile

from run_persistent_ui_probe import extract_candidate,run_child

FRAME=b'\nWEREAD_DIRECT_POSITION_OWNER_RUN='
REPO=Path(__file__).resolve().parent.parent


def frame(output,marker):
    lines=[line for line in output.splitlines() if line.startswith(marker)]
    if len(output)>65536 or len(lines)!=1:raise ValueError('frame')
    return json.loads(lines[0][len(marker):])


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800)
    parser.add_argument('--dpi',type=int,default=167)
    args=parser.parse_args(argv);runtime=args.koreader.resolve()
    if (sys.platform!='linux' or not (runtime/'luajit').is_file() or min(args.width,args.height,args.dpi)<1
            or not any(row.split()[1:3]==['/dev/shm','tmpfs'] for row in Path('/proc/mounts').read_text().splitlines())):
        parser.error('Linux, KOReader and tmpfs are required')
    report=dict(result='UNVERIFIED',profile_removed=False);root=None;phase='input'
    try:
        raw=sys.stdin.buffer.read(65537)
        if len(raw)>65536:raise ValueError('input_limit')
        payload=json.loads(raw)
        with tempfile.TemporaryDirectory(prefix='weread-native-position-owner-',dir='/dev/shm') as temporary:
            root=Path(temporary);profile=root/'profile';xdg=root/'xdg'
            (profile/'plugins').mkdir(parents=True);xdg.mkdir(mode=0o700)
            extract_candidate(args.candidate,profile/'plugins');plugin=profile/'plugins/weread.koplugin'
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(xdg),LD_LIBRARY_PATH=str(runtime/'libs'),
                SDL_VIDEODRIVER='dummy',EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi),
                WEREAD_DIRECT_OWNER_TMPFS='1')
            phase='native_chapter'
            code,out,repaint=run_child([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_owner_error_guard.lua'),
                str(plugin),str(REPO/'spec/koreader/native_direct_owner_ui_probe.lua')],env,raw,runtime,timeout=180)
            if code:
                report['probe_exit']=code
                match=re.search(rb'native_direct_owner_ui_probe\.lua:(\d+)',out)
                if not match:match=re.search(rb'WEREAD_DIRECT_OWNER_ERROR=(\d+)',out)
                if match:report['probe_line']=int(match.group(1))
            prepared=frame(out,b'WEREAD_DIRECT_OWNER=')
            if not prepared.get('ok'):
                if prepared.get('reason') in {'auth_expired','rate_limited','service_rejected','unavailable','not_entitled'}:
                    report['reason']=prepared['reason']
                raise ValueError('prepare')
            if code or repaint or prepared.get('source_matches') is not True:raise ValueError('prepare')
            path=Path(prepared['path'])
            if not path.is_file() or profile not in path.parents:raise ValueError('path')
            phase='reader_position'
            private=dict(path=str(path),book_id=payload['book_id'],uid=payload['uid'],credentials=payload['credentials'],
                web_cookies=payload['web_cookies'],cloud=payload.get('cloud') is True,start_page=payload.get('start_page',1))
            code,out,repaint=run_child([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_owner_position_probe.lua'),
                str(plugin)],env,json.dumps(private,ensure_ascii=False).encode(),runtime,timeout=180)
            position=frame(out,b'WEREAD_DIRECT_OWNER_POSITION=')
            if position.get('ok') is False and position.get('reason') in {'invalid','unavailable','source_changed',
                    'anchor_unavailable','source_unsupported','file_changed','session_changed','auth_expired','web_expired','rate_limited','cloud_changed'}:
                report['reason']=position['reason']
            fields={'ok','text','point_offset','offset'}
            if private['cloud']:
                fields|={'relation','opened'}
                if position.get('opened') is True:fields.add('target')
                if (position.get('relation') not in {'same','no_chapter','other_chapter','target_unavailable','different'}
                        or type(position.get('opened')) is not bool
                        or position['opened']!=(position['relation']=='different')):raise ValueError('cloud')
            if (code or repaint or set(position)!=fields or position['ok'] is not True
                    or not isinstance(position['text'],str) or not 1<=len(position['text'].encode())<=8192
                    or type(position['point_offset']) is not int or type(position['offset']) is not int):
                raise ValueError('position')
            phase='credential_audit'
            native=payload['credentials'];secrets=[native[key] for key in ('accessToken','refreshToken','deviceId')]
            secrets.extend(value for key,value in payload['web_cookies'].items()
                if key!='wr_vid' and isinstance(value,str) and len(value)>=8)
            for item in profile.rglob('*'):
                if item.is_symlink():raise ValueError('symlink')
                if item.is_file() and plugin not in item.parents:
                    if item.stat().st_size>128*1024*1024:raise ValueError('file_limit')
                    data=item.read_bytes()
                    if any(value.encode() in data for value in secrets):raise ValueError('credential_file')
            with zipfile.ZipFile(args.candidate) as archive:
                for item in archive.infolist():
                    if not item.is_dir() and archive.read(item)!=(profile/'plugins'/item.filename).read_bytes():
                        raise ValueError('installed_bytes')
            report.update(result='PASS',position=position,credential_file_audit=True,installed_bytes_match=True)
    except (Exception,KeyboardInterrupt):report['phase']=phase
    finally:report['profile_removed']=root is not None and not root.exists()
    sys.stdout.buffer.write(FRAME+json.dumps(report,ensure_ascii=False).encode()+b'\n')
    return 0 if report['result']=='PASS' and report['profile_removed'] else 1


if __name__=='__main__':raise SystemExit(main())
