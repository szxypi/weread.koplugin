#!/usr/bin/env python3
"""Private native-only chapter build and offline reopen in disposable tmpfs."""
import argparse
import json
import os
from pathlib import Path
import sys
import tempfile
import zipfile
from run_persistent_ui_probe import extract_candidate,run_child

FRAME=b'\nWEREAD_DIRECT_OWNER_RUN='


def line(output,marker):
    matches=[line for line in output.splitlines() if line.startswith(marker)]
    if len(output)>65536 or len(matches)!=1:raise ValueError('frame')
    return json.loads(matches[0][len(marker):])


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--ui',action='store_true',help='Exercise the native chapter selection menu')
    parser.add_argument('--neighbor',action='store_true',help='Verify adjacent native chapters through the reader menu')
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    args=parser.parse_args(argv);runtime=args.koreader.resolve()
    if args.neighbor and not args.ui:parser.error('--neighbor requires --ui')
    if (sys.platform!='linux' or not (runtime/'luajit').is_file() or min(args.width,args.height,args.dpi)<1
            or not any(row.split()[1:3]==['/dev/shm','tmpfs'] for row in Path('/proc/mounts').read_text().splitlines())):
        parser.error('Linux, KOReader and tmpfs are required')
    report=dict(result='UNVERIFIED',profile_removed=False);root=None
    try:
        raw=sys.stdin.buffer.read(65537)
        if len(raw)>65536:raise ValueError('input_limit')
        payload=json.loads(raw);repo=Path(__file__).resolve().parent.parent
        with tempfile.TemporaryDirectory(prefix='weread-native-direct-owner-',dir='/dev/shm') as temporary:
            root=Path(temporary);profile=root/'profile';xdg=root/'xdg'
            (profile/'plugins').mkdir(parents=True);xdg.mkdir(mode=0o700)
            extract_candidate(args.candidate,profile/'plugins');plugin=profile/'plugins/weread.koplugin'
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(xdg),LD_LIBRARY_PATH=str(runtime/'libs'),
                SDL_VIDEODRIVER='dummy',EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi),
                WEREAD_DIRECT_OWNER_TMPFS='1')
            probe='native_direct_owner_ui_probe.lua' if args.ui else 'native_direct_owner_probe.lua'
            code,out,repaint=run_child([str(runtime/'luajit'),str(repo/'spec/koreader'/probe),str(plugin)],
                                       env,raw,runtime,timeout=180)
            result=line(out,b'WEREAD_DIRECT_OWNER=')
            if not result.get('ok'):
                if type(result.get('requests')) is int and 0<=result['requests']<=69:
                    report['native_requests_before_stop']=result['requests']
                reason=result.get('reason')
                if reason in {'not_entitled','auth_expired','rate_limited','service_rejected','session_changed',
                              'catalog_changed','unavailable','invalid_source','invalid_image','remote_unsupported','storage'}:
                    report['reason']=reason
                raise ValueError('native_source')
            fields={'ok','path','requests','source_matches','missing_images'}
            if args.neighbor:fields|={'neighbor_path','neighbor_source_matches','neighbor_missing_images'}
            if code or repaint or set(result)!=fields or result['source_matches'] is not True \
                    or type(result['requests']) is not int or not 5<=result['requests']<=69 \
                    or type(result['missing_images']) is not int or not 0<=result['missing_images']<=64:
                raise ValueError('native_result')
            path=Path(result['path'])
            if not path.is_file() or profile not in path.parents:raise ValueError('native_path')
            if args.neighbor:
                neighbor_path=Path(result['neighbor_path'])
                if (not neighbor_path.is_file() or profile not in neighbor_path.parents or neighbor_path==path
                        or result['neighbor_source_matches'] is not True or type(result['neighbor_missing_images']) is not int
                        or not 0<=result['neighbor_missing_images']<=64):raise ValueError('neighbor_path')
            offline=json.dumps(dict(path=str(path),token=payload['search_token'],uid=payload['uid'],book_id=payload['book_id'],
                                    missing_images=result['missing_images']),
                               ensure_ascii=False).encode()
            code,out,repaint=run_child([str(runtime/'luajit'),str(repo/'spec/koreader/native_direct_owner_offline_probe.lua'),
                                        str(plugin),str(repo)],env,offline,runtime,timeout=90)
            expected=dict(ok=True,network_blocked=True,web_coordinates=False,manual_time_blocked=True,
                          missing_images=result['missing_images'],warning_verified=True)
            if code or repaint or line(out,b'WEREAD_DIRECT_OWNER_OFFLINE=')!=expected:raise ValueError('offline')
            if args.ui:
                cached_input=json.dumps(dict(path=str(path),book_id=payload['book_id'],vid=payload['credentials']['vid'])).encode()
                code,out,repaint=run_child([str(runtime/'luajit'),str(repo/'spec/koreader/native_direct_owner_cached_ui_probe.lua'),
                    str(plugin),str(repo)],env,cached_input,runtime,timeout=120)
                if code or repaint or line(out,b'WEREAD_DIRECT_OWNER_CACHED_UI=')!=dict(
                        ok=True,network_blocked=True,credentials_not_required=True):raise ValueError('offline_ui')
            if args.neighbor:
                neighbor=payload['neighbor']
                neighbor_input=json.dumps(dict(path=str(neighbor_path),token=neighbor['search_token'],uid=neighbor['uid'],
                    book_id=payload['book_id'],missing_images=result['neighbor_missing_images']),ensure_ascii=False).encode()
                code,out,repaint=run_child([str(runtime/'luajit'),str(repo/'spec/koreader/native_direct_owner_offline_probe.lua'),
                    str(plugin),str(repo)],env,neighbor_input,runtime,timeout=90)
                neighbor_expected=dict(ok=True,network_blocked=True,web_coordinates=False,manual_time_blocked=True,
                    missing_images=result['neighbor_missing_images'],warning_verified=True)
                if code or repaint or line(out,b'WEREAD_DIRECT_OWNER_OFFLINE=')!=neighbor_expected:raise ValueError('neighbor_offline')
                nav_input=json.dumps(dict(first=str(path),second=str(neighbor_path),vid=payload['credentials']['vid'])).encode()
                code,out,repaint=run_child([str(runtime/'luajit'),str(repo/'spec/koreader/native_direct_owner_neighbor_offline.lua'),
                    str(plugin),str(repo)],env,nav_input,runtime,timeout=120)
                if code or repaint or line(out,b'WEREAD_DIRECT_OWNER_NEIGHBOR_OFFLINE=')!=dict(
                        ok=True,network_blocked=True,credentials_not_required=True,roundtrip=True):raise ValueError('neighbor_navigation')
            credentials=payload['credentials']
            for path in profile.rglob('*'):
                if path.is_symlink():raise ValueError('link')
                if path.is_file() and plugin not in path.parents:
                    if path.stat().st_size>128*1024*1024:raise ValueError('file_limit')
                    data=path.read_bytes()
                    if any(credentials[key].encode() in data for key in ('accessToken','refreshToken','deviceId')):
                        raise ValueError('credential_file')
            with zipfile.ZipFile(args.candidate) as archive:
                for item in archive.infolist():
                    if not item.is_dir() and archive.read(item)!=(profile/'plugins'/item.filename).read_bytes():
                        raise ValueError('installed_bytes')
            report.update(result='PASS',native_requests=result['requests'],source_matches=True,offline_reopen=True,
                offline_network_guard=True,web_coordinates=False,manual_time_blocked=True,credential_file_audit=True,
                installed_bytes_match=True,missing_images=result['missing_images'],warning_verified=True)
            if args.neighbor:report.update(neighbor_matches=True,neighbor_offline_roundtrip=True,
                neighbor_missing_images=result['neighbor_missing_images'])
    except (Exception,KeyboardInterrupt):pass
    finally:report['profile_removed']=root is not None and not root.exists()
    sys.stdout.buffer.write(FRAME+json.dumps(report).encode()+b'\n')
    return 0 if report['result']=='PASS' and report['profile_removed'] else 1


if __name__=='__main__':raise SystemExit(main())
