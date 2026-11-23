#!/usr/bin/env python3
"""Private native-only chapter build and offline reopen in disposable tmpfs."""
import argparse
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import zipfile
from run_persistent_ui_probe import extract_candidate,run_child
from run_native_direct_position_owner import synthetic_endpoint_allowed

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
    parser.add_argument('--copies',action='store_true',help='Test a deliberately incomplete comparison copy offline')
    parser.add_argument('--image-refresh',action='store_true',help='Retry images after a controlled read-only missing-image fixture')
    parser.add_argument('--offline-search',action='store_true',help='Search real cached chapters in the installed reader')
    parser.add_argument('--online-search',action='store_true',help='Search online from both native chapters')
    parser.add_argument('--online-missing',action='store_true',help='Also test cancel and download in a clean profile')
    parser.add_argument('--require-images',type=int,default=0,help='Decode at least this many distinct chapter images offline')
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    args=parser.parse_args(argv);runtime=args.koreader.resolve()
    if args.neighbor and not args.ui:parser.error('--neighbor requires --ui')
    if args.copies and (not args.neighbor or args.online_search or args.offline_search):
        parser.error('--copies requires --neighbor and excludes search modes')
    if args.image_refresh and (not args.ui or args.neighbor or args.offline_search or args.online_search):
        parser.error('--image-refresh requires --ui and excludes neighbor and search modes')
    if args.offline_search and not args.neighbor:parser.error('--offline-search requires --neighbor')
    if args.online_search and (not args.neighbor or args.offline_search):parser.error('--online-search requires --neighbor only')
    if args.online_missing and not args.online_search:parser.error('--online-missing requires --online-search')
    if (sys.platform!='linux' or not (runtime/'luajit').is_file() or min(args.width,args.height,args.dpi)<1
            or not 0<=args.require_images<=64
            or not any(row.split()[1:3]==['/dev/shm','tmpfs'] for row in Path('/proc/mounts').read_text().splitlines())):
        parser.error('Linux, KOReader and tmpfs are required')
    report=dict(result='UNVERIFIED',profile_removed=False);root=None;phase='input'
    try:
        raw=sys.stdin.buffer.read(65537)
        if len(raw)>65536:raise ValueError('input_limit')
        payload=json.loads(raw);repo=Path(__file__).resolve().parent.parent
        if args.online_search and not synthetic_endpoint_allowed(payload,payload.get('mock_endpoint')):
            raise ValueError('synthetic_endpoint')
        with tempfile.TemporaryDirectory(prefix='weread-native-direct-owner-',dir='/dev/shm') as temporary:
            root=Path(temporary);profile=root/'profile';xdg=root/'xdg'
            (profile/'plugins').mkdir(parents=True);xdg.mkdir(mode=0o700)
            plugin_home=args.offline_search or args.online_search or args.copies or args.image_refresh
            if plugin_home:(profile/'settings').mkdir()
            extract_candidate(args.candidate,profile/'plugins');plugin=profile/'plugins/weread.koplugin'
            env=dict(os.environ,KO_HOME=str(profile),XDG_RUNTIME_DIR=str(xdg),LD_LIBRARY_PATH=str(runtime/'libs'),
                SDL_VIDEODRIVER='dummy',EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8',
                EMULATE_READER_W=str(args.width),EMULATE_READER_H=str(args.height),EMULATE_READER_DPI=str(args.dpi),
                WEREAD_DIRECT_OWNER_TMPFS='1')
            probe='native_direct_owner_ui_probe.lua' if args.ui else 'native_direct_owner_probe.lua'
            prepare=dict(payload,plugin_home=plugin_home,simulate_missing_images=args.image_refresh)
            phase='prepare'
            code,out,repaint=run_child([str(runtime/'luajit'),str(repo/'spec/koreader'/probe),str(plugin)],
                                       env,json.dumps(prepare,ensure_ascii=False).encode(),runtime,timeout=180)
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
            phase='offline_first'
            offline=json.dumps(dict(path=str(path),token=payload['search_token'],uid=payload['uid'],book_id=payload['book_id'],
                                    missing_images=result['missing_images'],plugin_home=plugin_home,required_images=args.require_images),
                               ensure_ascii=False).encode()
            code,out,repaint=run_child([str(runtime/'luajit'),str(repo/'spec/koreader/native_direct_owner_offline_probe.lua'),
                                        str(plugin),str(repo)],env,offline,runtime,timeout=90)
            expected=dict(ok=True,network_blocked=True,web_coordinates=False,manual_time_blocked=True,
                          missing_images=result['missing_images'],warning_verified=True)
            if code or repaint or line(out,b'WEREAD_DIRECT_OWNER_OFFLINE=')!=expected:raise ValueError('offline')
            if args.ui:
                phase='cached_ui'
                cached_input=json.dumps(dict(path=str(path),book_id=payload['book_id'],vid=payload['credentials']['vid'],
                                             plugin_home=plugin_home)).encode()
                code,out,repaint=run_child([str(runtime/'luajit'),str(repo/'spec/koreader/native_direct_owner_cached_ui_probe.lua'),
                    str(plugin),str(repo)],env,cached_input,runtime,timeout=120)
                if code or repaint or line(out,b'WEREAD_DIRECT_OWNER_CACHED_UI=')!=dict(
                        ok=True,network_blocked=True,credentials_not_required=True):raise ValueError('offline_ui')
            if args.image_refresh:
                phase='image_refresh'
                if not 1<=result['missing_images']<=64:raise ValueError('missing_fixture')
                private=dict(path=str(path),credentials=payload['credentials'],book_id=payload['book_id'],uid=payload['uid'],
                    initial_missing=result['missing_images'],owner=True,resume=True)
                if payload.get('mock_endpoint') is not None:private['mock_endpoint']=payload['mock_endpoint']
                code,out,repaint=run_child([str(runtime/'luajit'),str(repo/'spec/koreader/native_direct_image_refresh_probe.lua')],
                    env,json.dumps(private,ensure_ascii=False).encode(),runtime,timeout=300)
                refreshed=line(out,b'WEREAD_DIRECT_IMAGE_REFRESH=');improved=Path(refreshed.get('path',''))
                if (code or repaint or set(refreshed)!={'ok','path','original_kept','page_unchanged','source_equal','missing_before','missing_after','resumed_at_page'}
                        or any(refreshed[key] is not True for key in ('ok','original_kept','page_unchanged','source_equal','resumed_at_page'))
                        or refreshed['missing_before']!=result['missing_images'] or refreshed['missing_after']!=0
                        or not improved.is_file() or profile not in improved.parents or improved==path):raise ValueError('refresh_result')
                phase='image_refresh_offline'
                improved_input=json.dumps(dict(path=str(improved),token=payload['search_token'],uid=payload['uid'],
                    book_id=payload['book_id'],missing_images=0,required_images=result['missing_images'],plugin_home=True),
                    ensure_ascii=False).encode()
                code,out,repaint=run_child([str(runtime/'luajit'),str(repo/'spec/koreader/native_direct_owner_offline_probe.lua'),
                    str(plugin),str(repo)],env,improved_input,runtime,timeout=90)
                improved_expected=dict(ok=True,network_blocked=True,web_coordinates=False,manual_time_blocked=True,
                    missing_images=0,warning_verified=True)
                if code or repaint or line(out,b'WEREAD_DIRECT_OWNER_OFFLINE=')!=improved_expected:raise ValueError('refresh_offline')
            if args.neighbor:
                phase='offline_neighbor'
                neighbor=payload['neighbor']
                neighbor_input=json.dumps(dict(path=str(neighbor_path),token=neighbor['search_token'],uid=neighbor['uid'],
                    book_id=payload['book_id'],missing_images=result['neighbor_missing_images'],
                    plugin_home=plugin_home),ensure_ascii=False).encode()
                code,out,repaint=run_child([str(runtime/'luajit'),str(repo/'spec/koreader/native_direct_owner_offline_probe.lua'),
                    str(plugin),str(repo)],env,neighbor_input,runtime,timeout=90)
                neighbor_expected=dict(ok=True,network_blocked=True,web_coordinates=False,manual_time_blocked=True,
                    missing_images=result['neighbor_missing_images'],warning_verified=True)
                if code or repaint or line(out,b'WEREAD_DIRECT_OWNER_OFFLINE=')!=neighbor_expected:raise ValueError('neighbor_offline')
                missing_copy=None
                if args.copies:
                    phase='prepare_missing_copy'
                    if result['neighbor_missing_images']!=0:raise ValueError('neighbor_images')
                    copy_input=json.dumps(dict(path=str(neighbor_path),vid=payload['credentials']['vid'],plugin_home=plugin_home)).encode()
                    code,out,repaint=run_child([str(runtime/'luajit'),str(repo/'spec/koreader/native_direct_owner_missing_copy.lua'),
                        str(plugin),str(repo)],env,copy_input,runtime,timeout=120)
                    saved=line(out,b'WEREAD_DIRECT_OWNER_MISSING_COPY=');missing_copy=Path(saved.get('path',''))
                    if (code or repaint or saved.get('ok') is not True or not missing_copy.is_file()
                            or profile not in missing_copy.parents or missing_copy==neighbor_path):raise ValueError('missing_copy')
                    phase='offline_missing_copy'
                    copy_offline=json.dumps(dict(path=str(missing_copy),token=neighbor['search_token'],uid=neighbor['uid'],
                        book_id=payload['book_id'],missing_images=1,plugin_home=plugin_home),ensure_ascii=False).encode()
                    code,out,repaint=run_child([str(runtime/'luajit'),str(repo/'spec/koreader/native_direct_owner_offline_probe.lua'),
                        str(plugin),str(repo)],env,copy_offline,runtime,timeout=90)
                    copy_expected=dict(ok=True,network_blocked=True,web_coordinates=False,manual_time_blocked=True,
                        missing_images=1,warning_verified=True)
                    if code or repaint or line(out,b'WEREAD_DIRECT_OWNER_OFFLINE=')!=copy_expected:raise ValueError('copy_offline')
                phase='neighbor_navigation'
                navigation=dict(first=str(path),second=str(neighbor_path),vid=payload['credentials']['vid'],plugin_home=plugin_home)
                if missing_copy:navigation['missing_copy']=str(missing_copy)
                nav_input=json.dumps(navigation).encode()
                code,out,repaint=run_child([str(runtime/'luajit'),str(repo/'spec/koreader/native_direct_owner_neighbor_offline.lua'),
                    str(plugin),str(repo)],env,nav_input,runtime,timeout=120)
                expected_nav=dict(ok=True,network_blocked=True,credentials_not_required=True,roundtrip=True)
                if args.copies:expected_nav['copies_selected']=True
                if code or repaint or line(out,b'WEREAD_DIRECT_OWNER_NEIGHBOR_OFFLINE=')!=expected_nav:raise ValueError('neighbor_navigation')
                if args.copies:
                    phase='copies_reader'
                    reader_input=json.dumps(dict(first=str(path),second=str(neighbor_path),missing_copy=str(missing_copy),
                        vid=payload['credentials']['vid'])).encode()
                    code,out,repaint=run_child([str(runtime/'luajit'),str(repo/'spec/koreader/native_direct_owner_copies_reader.lua'),
                        str(repo)],env,reader_input,runtime,timeout=300)
                    if code:
                        stages=re.findall(rb'(?m)^WEREAD_COPY_READER_STAGE=(open|first_page|complete_page|incomplete_page)$',out)
                        if stages:report['reader_stage']=stages[-1].decode()
                    expected_reader=dict(ok=True,offline=True,installed_plugin=True,distinct_positions=True)
                    if code or repaint or line(out,b'WEREAD_DIRECT_OWNER_COPY_READER=')!=expected_reader:raise ValueError('copies_reader')
                if args.offline_search:
                    phase='offline_search'
                    search_input=json.dumps(dict(first=str(path),second=str(neighbor_path),vid=payload['credentials']['vid'],
                        uid=payload['uid'],token=payload['search_token']),ensure_ascii=False).encode()
                    code,out,repaint=run_child([str(runtime/'luajit'),str(repo/'spec/koreader/native_direct_owner_error_guard.lua'),
                                                str(repo),str(repo/'spec/koreader/native_direct_owner_search_offline.lua')],
                                               env,search_input,runtime,timeout=240)
                    if code:
                        match=re.search(rb'WEREAD_DIRECT_OWNER_ERROR=(\d+)',out)
                        if match:report['probe_line']=int(match.group(1))
                        stage=re.search(rb'(?m)^WEREAD_DIRECT_SEARCH_STAGE=(reader|quick|input|results|switch|locate)$',out)
                        if stage:report['probe_stage']=stage.group(1).decode()
                    if code or repaint or line(out,b'WEREAD_DIRECT_OWNER_SEARCH=')!=dict(ok=True,network_blocked=True,
                            credentials_not_required=True,installed_plugin=True,cross_chapter=True,independent_text=True):
                        raise ValueError('offline_search')
                if args.online_search:
                    phase='online_search'
                    for cross in (False,True):
                        private=dict(path=str(neighbor_path if cross else path),book_id=payload['book_id'],uid=payload['uid'],
                            credentials=payload['credentials'],web_cookies=payload['web_cookies'],cross=cross,
                            keyword=payload['online_search']['keyword'],start=payload['online_search']['start'],
                            finish=payload['online_search']['finish'],allowed=payload['online_search']['allowed'])
                        if payload.get('mock_endpoint') is not None:private['mock_endpoint']=payload['mock_endpoint']
                        code,out,repaint=run_child([str(runtime/'luajit'),str(repo/'spec/koreader/native_direct_owner_error_guard.lua'),
                            str(repo),str(repo/'spec/koreader/native_direct_owner_search_online.lua')],env,
                            json.dumps(private,ensure_ascii=False).encode(),runtime,timeout=300)
                        if code:
                            match=re.search(rb'WEREAD_DIRECT_OWNER_ERROR=(\d+)',out)
                            if match:report['probe_line']=int(match.group(1))
                            stage=re.search(rb'(?m)^WEREAD_DIRECT_ONLINE_STAGE=(reader|quick|input|results|switch|locate)$',out)
                            if stage:report['probe_stage']=stage.group(1).decode()
                        online=line(out,b'WEREAD_DIRECT_OWNER_ONLINE_SEARCH=')
                        if (code or repaint or set(online)!={'ok','cross','installed_plugin','independent_text','blocked_requests','search_requests'}
                                or online['ok'] is not True or online['cross'] is not cross or online['installed_plugin'] is not True
                                or online['independent_text'] is not True or online['blocked_requests']!=0
                                or type(online['search_requests']) is not int or not 1<=online['search_requests']<=len(private['allowed'])):
                            raise ValueError('online_search')
                    if args.online_missing:
                        phase='online_missing_prepare'
                        missing_profile=root/'missing-profile';(missing_profile/'plugins').mkdir(parents=True)
                        (missing_profile/'settings').mkdir();extract_candidate(args.candidate,missing_profile/'plugins')
                        missing_plugin=missing_profile/'plugins/weread.koplugin';missing_env=dict(env,KO_HOME=str(missing_profile))
                        only_source=dict(payload,uid=payload['neighbor']['uid'],source_sha256=payload['neighbor']['source_sha256'],
                            search_token=payload['neighbor']['search_token'],plugin_home=True)
                        only_source.pop('neighbor')
                        code,out,repaint=run_child([str(runtime/'luajit'),str(repo/'spec/koreader/native_direct_owner_error_guard.lua'),
                            str(missing_plugin),str(repo/'spec/koreader/native_direct_owner_ui_probe.lua')],missing_env,
                            json.dumps(only_source,ensure_ascii=False).encode(),runtime,timeout=180)
                        prepared=line(out,b'WEREAD_DIRECT_OWNER=');source=Path(prepared.get('path',''))
                        if (code or repaint or prepared.get('ok') is not True or prepared.get('source_matches') is not True
                                or not source.is_file() or missing_profile not in source.parents):raise ValueError('missing_source')
                        phase='online_missing_search'
                        private=dict(path=str(source),book_id=payload['book_id'],uid=payload['uid'],credentials=payload['credentials'],
                            web_cookies=payload['web_cookies'],cross=True,missing=True,target_sha256=payload['source_sha256'],
                            keyword=payload['online_search']['keyword'],start=payload['online_search']['start'],
                            finish=payload['online_search']['finish'],allowed=payload['online_search']['allowed'])
                        if payload.get('mock_endpoint') is not None:private['mock_endpoint']=payload['mock_endpoint']
                        code,out,repaint=run_child([str(runtime/'luajit'),str(repo/'spec/koreader/native_direct_owner_error_guard.lua'),
                            str(repo),str(repo/'spec/koreader/native_direct_owner_search_online.lua')],missing_env,
                            json.dumps(private,ensure_ascii=False).encode(),runtime,timeout=300)
                        if code:
                            match=re.search(rb'WEREAD_DIRECT_OWNER_ERROR=(\d+)',out)
                            if match:report['probe_line']=int(match.group(1))
                            stage=re.search(rb'(?m)^WEREAD_DIRECT_ONLINE_STAGE=(reader|quick|input|results|confirm|switch|locate)$',out)
                            if stage:report['probe_stage']=stage.group(1).decode()
                        online=line(out,b'WEREAD_DIRECT_OWNER_ONLINE_SEARCH=')
                        if (code or repaint or set(online)!={'ok','cross','installed_plugin','independent_text','blocked_requests',
                                'search_requests','cancel_without_download','downloaded_source_matches'}
                                or any(online[key] is not True for key in ('ok','cross','installed_plugin','independent_text',
                                    'cancel_without_download','downloaded_source_matches')) or online['blocked_requests']!=0
                                or type(online['search_requests']) is not int or not 1<=online['search_requests']<=len(private['allowed'])):
                            raise ValueError('online_missing')
            phase='audit';credentials=payload['credentials']
            secrets=[credentials[key] for key in ('accessToken','refreshToken','deviceId')]
            if args.online_search:
                secrets.extend(value for key,value in payload['web_cookies'].items()
                    if key!='wr_vid' and isinstance(value,str) and len(value)>=8)
            profiles=[(profile,plugin)]
            if args.online_missing:profiles.append((missing_profile,missing_plugin))
            for checked_profile,checked_plugin in profiles:
                for path in checked_profile.rglob('*'):
                    if path.is_symlink():raise ValueError('link')
                    if path.is_file() and checked_plugin not in path.parents:
                        if path.stat().st_size>128*1024*1024:raise ValueError('file_limit')
                        data=path.read_bytes()
                        if any(secret.encode() in data for secret in secrets):raise ValueError('credential_file')
            with zipfile.ZipFile(args.candidate) as archive:
                for checked_profile,_ in profiles:
                    for item in archive.infolist():
                        if not item.is_dir() and archive.read(item)!=(checked_profile/'plugins'/item.filename).read_bytes():
                            raise ValueError('installed_bytes')
            report.update(result='PASS',native_requests=result['requests'],source_matches=True,offline_reopen=True,
                offline_network_guard=True,web_coordinates=False,manual_time_blocked=True,credential_file_audit=True,
                installed_bytes_match=True,missing_images=result['missing_images'],warning_verified=True)
            if args.neighbor:report.update(neighbor_matches=True,neighbor_offline_roundtrip=True,
                neighbor_missing_images=result['neighbor_missing_images'])
            if args.copies:report.update(copies_offline_verified=True,copies_reader_positions=True)
            if args.image_refresh:report.update(image_refresh_verified=True,image_refresh_missing_before=result['missing_images'],
                image_refresh_missing_after=0,image_refresh_resumed=True)
            if args.offline_search:report['offline_search']=True
            if args.online_search:report['online_search']=True
            if args.online_missing:report['online_missing']=True
    except (Exception,KeyboardInterrupt):report['phase']=phase
    finally:report['profile_removed']=root is not None and not root.exists()
    sys.stdout.buffer.write(FRAME+json.dumps(report).encode()+b'\n')
    return 0 if report['result']=='PASS' and report['profile_removed'] else 1


if __name__=='__main__':raise SystemExit(main())
