#!/usr/bin/env python3
"""Private KOReader owner mark display/reopen runner in a RAM-backed profile."""
import argparse
import json
import os
from pathlib import Path
import re
import resource
import signal
import sys
import tempfile
import zipfile

from run_persistent_ui_probe import extract_candidate,run_child
from run_native_direct_position_owner import frame,synthetic_endpoint_allowed

REPO=Path(__file__).resolve().parent.parent
FRAME=b'\nWEREAD_DIRECT_PERSONAL_OWNER_RUN='


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    args=parser.parse_args(argv);runtime=args.koreader.resolve()
    if (sys.platform!='linux' or not (runtime/'luajit').is_file() or not all(1<=n<=4096 for n in (args.width,args.height,args.dpi))
            or not any(row.split()[1:3]==['/dev/shm','tmpfs'] for row in Path('/proc/mounts').read_text().splitlines())):
        parser.error('Linux, KOReader and tmpfs required')
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));report={'result':'UNVERIFIED','profile_removed':False};root=None;phase='input'
    try:
        raw=sys.stdin.buffer.read(65537)
        if len(raw)>65536:raise ValueError('input')
        payload=json.loads(raw)
        if not synthetic_endpoint_allowed(payload,payload.get('mock_endpoint')):raise ValueError('endpoint')
        if payload.get('expect_bookmarks') is True:
            def expired(_signal,_frame):raise RuntimeError('cross_bookmark/runner_timeout')
            signal.signal(signal.SIGALRM,expired);signal.alarm(200)
        with tempfile.TemporaryDirectory(prefix='weread-direct-personal-owner-',dir='/dev/shm') as directory:
            root=Path(directory);profile=root/'profile';xdg=root/'xdg'
            (profile/'plugins').mkdir(parents=True);xdg.mkdir(mode=0o700);extract_candidate(args.candidate,profile/'plugins')
            plugin=profile/'plugins/weread.koplugin'
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(xdg),LD_LIBRARY_PATH=str(runtime/'libs'),
                SDL_VIDEODRIVER='dummy',EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi),WEREAD_DIRECT_OWNER_TMPFS='1')
            phase='prepare';payload['plugin_home']=True
            prepare_payload=dict(payload)
            if payload.get('cross_chapter') is True:
                prepare_payload.update(uid=payload['origin_uid'],source_sha256=payload['origin_source_sha256'])
            raw=json.dumps(prepare_payload,ensure_ascii=False,separators=(',',':')).encode()
            code,out,repaint=run_child([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_owner_error_guard.lua'),
                str(plugin),str(REPO/'spec/koreader/native_direct_owner_ui_probe.lua')],env,raw,runtime,timeout=180)
            prepared=frame(out,b'WEREAD_DIRECT_OWNER=')
            if prepared.get('reason') in {'not_entitled','auth_expired','rate_limited','service_rejected','session_changed',
                    'catalog_changed','unavailable','invalid_source','invalid_image','remote_unsupported','storage'}:
                report['reason']=prepared['reason']
            if code:
                match=re.search(rb'WEREAD_DIRECT_OWNER_ERROR=(\d+)',out)
                if match:report['probe_line']=int(match.group(1))
            path=Path(prepared.get('path',''))
            if code or repaint or not prepared.get('ok') or not prepared.get('source_matches') or not path.is_file() or profile not in path.parents:
                raise ValueError('prepare')
            payload['path']=str(path);stages=[]
            for offline in (False,True):
                phase='offline' if offline else 'online';payload['offline']=offline
                probe='native_direct_cross_owner_probe.lua' if payload.get('cross_chapter') is True else 'native_direct_personal_owner_probe.lua'
                code,out,repaint=run_child([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_owner_error_guard.lua'),
                    str(plugin),str(REPO/'spec/koreader'/probe)],env,
                    json.dumps(payload,ensure_ascii=False,separators=(',',':')).encode(),runtime,timeout=180)
                if code:
                    try:
                        diagnostic=frame(out,b'WEREAD_DIRECT_PERSONAL_STATE=')
                        if isinstance(diagnostic,dict) and all(type(value) is bool or type(value) is int and 0<=value<=5000 or isinstance(value,dict) and all(type(v) is bool for v in value.values()) for value in diagnostic.values()):report['diagnostic']=diagnostic
                        flow=profile/'personal-flow-diagnostic'
                        if flow.is_file() and flow.stat().st_size<=8192:
                            lines=flow.read_text().splitlines()
                            if all(re.fullmatch(r'(?:prepared_[0-9]+|verify_[0-9]+_[0-9]+|index_failed|span_[a-z_]+|search_[a-z_]+|hits_[0-9]+)',value) for value in lines):report['flow']=lines[:100]
                        trace=profile/'personal-span-diagnostic'
                        if trace.is_file() and trace.stat().st_size<=8192:
                            reasons=trace.read_text().splitlines()
                            if all(re.fullmatch(r'my_mark_span/[a-z_]+',value) for value in reasons):report['span_reasons']=reasons[:100]
                    except ValueError:pass
                    match=re.search(rb'WEREAD_DIRECT_OWNER_ERROR=(\d+)',out)
                    if match:report['probe_line']=int(match.group(1))
                stage=frame(out,b'WEREAD_DIRECT_PERSONAL_OWNER=')
                fields={'ok','offline','rows','navigation'}
                if (code or repaint or not isinstance(stage,dict) or set(stage)!=fields or stage['ok'] is not True
                        or 'navigation' in stage and stage['navigation'] is not True
                        or stage['offline'] is not offline or not isinstance(stage['rows'],list) or not 1<=len(stage['rows'])<=100):
                    raise ValueError('stage')
                for row in stage['rows']:
                    fields={'id','range','text'}|({'content_sha256'} if payload.get('expect_thoughts') is True else set())
                    if (not isinstance(row,dict) or set(row)!=fields or any(not isinstance(row[k],str) for k in row)
                            or 'content_sha256' in row and not re.fullmatch(r'[0-9a-f]{64}',row['content_sha256'])
                            or not 1<=len(row['id'])<=256 or not 1<=len(row['range'])<=32 or not 1<=len(row['text'].encode())<=4096):
                        raise ValueError('rows')
                stages.append(stage)
            if stages[0]['rows']!=stages[1]['rows']:raise ValueError('reopen')
            phase='audit';secrets=[payload['credentials'][key] for key in ('accessToken','refreshToken','deviceId')]
            secrets.extend(value for key,value in payload['web_cookies'].items() if key!='wr_vid' and isinstance(value,str) and len(value)>=8)
            for item in profile.rglob('*'):
                if item.is_symlink():raise ValueError('symlink')
                if item.is_file() and plugin not in item.parents:
                    if item.stat().st_size>128*1024*1024:raise ValueError('limit')
                    data=item.read_bytes()
                    if any(value.encode() in data for value in secrets):raise ValueError('credential_file')
            with zipfile.ZipFile(args.candidate) as archive:
                for item in archive.infolist():
                    if not item.is_dir() and archive.read(item)!=(profile/'plugins'/item.filename).read_bytes():raise ValueError('installed')
            report.update(result='PASS',rows=stages[0]['rows'],offline_reopen=True,credential_file_audit=True,installed_bytes_match=True)
            report['navigation']=True
    except (Exception,KeyboardInterrupt):report['phase']=phase
    finally:
        signal.alarm(0);report['profile_removed']=root is not None and not root.exists()
    sys.stdout.buffer.write(FRAME+json.dumps(report,ensure_ascii=False).encode()+b'\n')
    return int(report['result']!='PASS' or not report['profile_removed'])


if __name__=='__main__':raise SystemExit(main())
