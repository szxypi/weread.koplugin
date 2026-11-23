#!/usr/bin/env python3
"""Read-only native chapter and offline home resume in a disposable tmpfs profile."""
import argparse
import json
import os
from pathlib import Path
import re
import resource
import sys
import tempfile
import zipfile

from run_native_direct_position_owner import frame, synthetic_endpoint_allowed
from run_persistent_ui_probe import extract_candidate, run_child

REPO = Path(__file__).resolve().parent.parent
FRAME = b'\nWEREAD_DIRECT_HOME_OWNER_RUN='


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--width', type=int, default=600)
    parser.add_argument('--height', type=int, default=800)
    parser.add_argument('--dpi', type=int, default=167)
    parser.add_argument('--full-ui', action='store_true')
    parser.add_argument('--store-search', action='store_true')
    parser.add_argument('--quick-search', action='store_true')
    parser.add_argument('--progress-estimate', action='store_true')
    parser.add_argument('--offline-reminder', action='store_true')
    parser.add_argument('--offline-time', action='store_true')
    parser.add_argument('--offline-time-ui', action='store_true')
    args = parser.parse_args(argv)
    if args.store_search and not args.full_ui:
        parser.error('store search requires full UI')
    if args.quick_search and not args.store_search:
        parser.error('quick search requires store search')
    if args.progress_estimate and not args.full_ui:
        parser.error('progress estimate requires full UI')
    if args.offline_reminder and not args.full_ui:
        parser.error('offline reminder requires full UI')
    if args.offline_time and not args.full_ui:
        parser.error('offline time requires full UI')
    if args.offline_time_ui and not args.offline_time:
        parser.error('offline time UI requires offline time')
    runtime = args.koreader.resolve()
    if (sys.platform != 'linux' or not (runtime/'luajit').is_file()
            or not all(1 <= value <= 4096 for value in (args.width, args.height, args.dpi))
            or not any(row.split()[1:3] == ['/dev/shm', 'tmpfs'] for row in Path('/proc/mounts').read_text().splitlines())):
        parser.error('Linux, KOReader and tmpfs required')
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    report = dict(result='UNVERIFIED', profile_removed=False)
    root = None
    phase = 'input'
    try:
        raw = sys.stdin.buffer.read(65537)
        if len(raw) > 65536:
            raise ValueError('input_limit')
        payload = json.loads(raw)
        if not synthetic_endpoint_allowed(payload, payload.get('mock_endpoint')):
            raise ValueError('endpoint')
        if args.store_search != (isinstance(payload.get('store_search_keyword'), str)
                and 0 < len(payload['store_search_keyword'].encode()) <= 512):
            raise ValueError('search_keyword')
        if args.store_search and (not isinstance(payload.get('inline_style'),str)
                or not 0<len(payload['inline_style'].encode())<=32768):
            raise ValueError('inline_style')
        progress=payload.get('progress_estimate')
        if args.progress_estimate:
            if (not isinstance(progress,dict) or set(progress)!={'order','count','before','words','total'}
                    or any(type(value) is not int for value in progress.values())
                    or not 1<=progress['order']<=progress['count']<=20000
                    or not 0<=progress['before']<progress['total']<=2000000000000
                    or not 0<progress['words']<=progress['total']-progress['before']):
                raise ValueError('progress_estimate')
        elif progress is not None:
            raise ValueError('progress_estimate')
        with tempfile.TemporaryDirectory(prefix='weread-native-home-owner-', dir='/dev/shm') as directory:
            root = Path(directory)
            profile, xdg = root/'profile', root/'xdg'
            (profile/'plugins').mkdir(parents=True)
            xdg.mkdir(mode=0o700)
            extract_candidate(args.candidate, profile/'plugins')
            plugin = profile/'plugins/weread.koplugin'
            env = dict(os.environ, KO_HOME=str(profile), XDG_RUNTIME_DIR=str(xdg), LD_LIBRARY_PATH=str(runtime/'libs'),
                       SDL_VIDEODRIVER='dummy', EMULATE_READER='1', EMULATE_BW_SCREEN='1', EMULATE_BB_TYPE='BB8',
                       EMULATE_READER_W=str(args.width), EMULATE_READER_H=str(args.height),
                       EMULATE_READER_DPI=str(args.dpi), WEREAD_DIRECT_OWNER_TMPFS='1')
            if args.offline_time_ui: env['TZ'] = 'Asia/Shanghai'
            phase = 'native_chapter'
            prepare = dict(payload, plugin_home=True, quick_search=args.quick_search)
            probe = 'native_direct_home_full_owner_probe.lua' if args.full_ui else 'native_direct_owner_ui_probe.lua'
            probe_marker = b'WEREAD_DIRECT_HOME_FULL=' if args.full_ui else b'WEREAD_DIRECT_OWNER='
            code, out, repaint = run_child([str(runtime/'luajit'), str(REPO/'spec/koreader/native_direct_owner_error_guard.lua'),
                                            str(plugin), str(REPO/'spec/koreader'/probe)], env,
                                           json.dumps(prepare, ensure_ascii=False).encode(), runtime, timeout=180)
            if code:
                match = re.search(rb'WEREAD_DIRECT_OWNER_ERROR=(\d+)', out)
                if match:
                    report['probe_line'] = int(match.group(1))
                stage = re.search(rb'(?m)^WEREAD_DIRECT_HOME_STAGE=(search_dialog|search_results|details|catalog|reader|home_record|quick_menu|quick_input|quick_results)$',out)
                if stage:
                    report['probe_stage'] = stage.group(1).decode()
                reason = re.search(rb'(?m)^WEREAD_DIRECT_HOME_REASON=(not_entitled|auth_expired|rate_limited|service_rejected|session_changed|catalog_changed|unavailable|invalid_source|invalid_image|remote_unsupported|storage|resource_[a-z_]+)$',out)
                if reason:
                    value=reason.group(1).decode()
                    resources={'missing','unsupported','ambiguous','inline_style','css','css_import','css_url','html','body',
                               'link_tag','style_tag','unsupported_markup','background_attribute','other_source_attribute',
                               'multiple_styles','source','source_changed','asset','assets','remote_limit','missing_limit','options','unavailable'}
                    if not value.startswith('resource_') or value[9:] in resources:
                        report['reason'] = value
                for name,allowed in (('archive',{'ok','filename','entry_limit','password','checksum','manifest_chapter',
                                                  'body_selection','manifest_parse','body_limit','other'}),
                                     ('download',{'http_200','http_401','http_429','http_other','transport'})):
                    item=profile/('native-home-'+name)
                    if item.is_file() and item.stat().st_size<=32:
                        value=item.read_text()
                        if value in allowed:
                            report[name+'_status']=value
                item=profile/'native-home-payload'
                if item.is_file() and item.stat().st_size<=32:
                    value=item.read_text()
                    if value in {kind+'_'+key for kind in ('empty','zip','json','other') for key in ('key','nokey','duplicate')}:
                        report['payload_status']=value
            prepared = frame(out, probe_marker)
            if prepared.get('reason') in {'not_entitled', 'auth_expired', 'rate_limited', 'service_rejected',
                                         'session_changed', 'catalog_changed', 'unavailable', 'invalid_source',
                                         'invalid_image', 'remote_unsupported', 'storage'}:
                report['reason'] = prepared['reason']
            path = Path(prepared.get('path', ''))
            if (code or repaint or prepared.get('ok') is not True or prepared.get('source_matches') is not True
                    or type(prepared.get('requests')) is not int or not 5 <= prepared['requests'] <= 69
                    or args.full_ui and prepared.get('store_search') is not args.store_search
                    or args.full_ui and prepared.get('quick_search') is not args.quick_search
                    or not path.is_file() or profile/'weread' not in path.parents):
                raise ValueError('prepare')
            for mode in (('reopen',) if args.full_ui else ('record', 'reopen')):
                phase = mode
                private = dict(mode=mode, path=str(path), book_id=payload['book_id'], vid=payload['credentials']['vid'])
                if args.store_search:
                    private['store_search'] = True
                if args.progress_estimate:
                    private['progress_estimate'] = progress
                code, out, repaint = run_child([str(runtime/'luajit'), str(REPO/'spec/koreader/native_direct_owner_error_guard.lua'),
                                                str(REPO), str(REPO/'spec/koreader/native_home_resume_probe.lua')], env,
                                               json.dumps(private).encode(), runtime, timeout=150)
                if code:
                    match = re.search(rb'WEREAD_DIRECT_OWNER_ERROR=(\d+)', out)
                    if match:
                        report['probe_line'] = int(match.group(1))
                expected=dict(ok=True, mode=mode, network_blocked=True)
                if args.progress_estimate: expected['progress_estimate']=True
                if code or repaint or frame(out, b'WEREAD_NATIVE_HOME=') != expected:
                    raise ValueError('home')
            if args.offline_time:
                phase = 'offline_time'
                saved = None
                for stage in (('capture', 'reopen', 'reopen_review') if args.offline_time_ui else ('capture', 'reopen')):
                    private = dict(stage=stage, path=str(path), book_id=payload['book_id'], vid=payload['credentials']['vid'])
                    code, out, repaint = run_child([str(runtime/'luajit'), str(REPO/'spec/koreader/native_direct_owner_error_guard.lua'),
                        str(REPO), str(REPO/'spec/koreader/native_direct_time_owner_probe.lua')], env,
                        json.dumps(private).encode(), runtime, timeout=150)
                    if code:
                        match = re.search(rb'WEREAD_DIRECT_OWNER_ERROR=(\d+)', out)
                        if match: report['probe_line'] = int(match.group(1))
                        diagnostic = re.search(rb'WEREAD_DIRECT_TIME_DIAGNOSTIC=((?:reader|collector)_(?:none|disabled|reader_hidden|native_time_checking|native_time_unavailable|recording_native|statistics_unavailable|paused|no_book|error))', out)
                        if diagnostic: report['time_diagnostic'] = diagnostic.group(1).decode()
                    observed = frame(out, b'WEREAD_DIRECT_TIME_OWNER=')
                    if (code or repaint or observed.get('ok') is not True or observed.get('stage') != stage
                            or observed.get('network_blocked') is not True
                            or type(observed.get('rows')) is not int or observed['rows'] < 1
                            or type(observed.get('seconds')) is not int or observed['seconds'] < 5
                            or not isinstance(observed.get('snapshot'), str)
                            or re.fullmatch(r'[0-9a-f]{64}', observed['snapshot']) is None
                            or observed.get('review_verified') is not (stage == 'reopen_review')):
                        raise ValueError('offline_time')
                    point = observed['rows'], observed['seconds'], observed['snapshot']
                    if saved is not None and point != saved: raise ValueError('offline_time_changed')
                    saved = point
            if args.offline_reminder:
                phase='offline_reminder'
                for stage in ('save','conflict_cancel_close','reopen_replace','save','manual_conflict','save','manual_offline','discard_cancel','different','restore','manual_restore',
                              'manual_discard','save','discard','cleared'):
                    private=dict(stage=stage,path=str(path),book_id=payload['book_id'],vid=payload['credentials']['vid'])
                    code,out,repaint=run_child([str(runtime/'luajit'),str(REPO/'spec/koreader/native_direct_owner_error_guard.lua'),
                        str(REPO),str(REPO/'spec/koreader/native_direct_pending_reader_probe.lua')],env,
                        json.dumps(private).encode(),runtime,timeout=150)
                    if code:
                        match=re.search(rb'WEREAD_DIRECT_OWNER_ERROR=(\d+)',out)
                        if match: report['probe_line']=int(match.group(1))
                    if code or repaint or frame(out,b'WEREAD_DIRECT_PENDING_READER=')!=dict(ok=True,stage=stage,network_blocked=True):
                        raise ValueError('offline_reminder')
            phase = 'audit'
            credentials = payload['credentials']
            secrets = [credentials[key].encode() for key in ('accessToken', 'refreshToken', 'deviceId')]
            for item in profile.rglob('*'):
                if item.is_symlink():
                    raise ValueError('symlink')
                if item.is_file() and plugin not in item.parents:
                    if item.stat().st_size > 128*1024*1024:
                        raise ValueError('file_limit')
                    content = item.read_bytes()
                    if any(secret in content for secret in secrets):
                        raise ValueError('credential_file')
            with zipfile.ZipFile(args.candidate) as archive:
                for item in archive.infolist():
                    if not item.is_dir() and archive.read(item) != (profile/'plugins'/item.filename).read_bytes():
                        raise ValueError('installed_bytes')
            report.update(result='PASS', native_requests=prepared['requests'], source_matches=True,
                          home_record=True, offline_home_resume=True, page_restored=True, network_blocked=True,
                          credential_file_audit=True, installed_bytes_match=True)
            if args.full_ui:
                report['full_ui'] = True
            if args.store_search:
                report['store_search'] = True
                report['inline_style_verified'] = True
            if args.quick_search:
                report['quick_search'] = True
            if args.progress_estimate:
                report['progress_estimate_verified'] = True
            if args.offline_reminder:
                report['offline_reminder_verified'] = True
            if args.offline_time:
                report['offline_time_verified'] = True
            if args.offline_time_ui:
                report['offline_time_ui_verified'] = True
    except (Exception, KeyboardInterrupt):
        report['phase'] = phase
    finally:
        report['profile_removed'] = root is not None and not root.exists()
    sys.stdout.buffer.write(FRAME + json.dumps(report).encode() + b'\n')
    return int(report['result'] != 'PASS' or not report['profile_removed'])


if __name__ == '__main__':
    raise SystemExit(main())
