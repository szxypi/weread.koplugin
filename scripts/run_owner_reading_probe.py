#!/usr/bin/env python3
"""Linux-only native reading acceptance with a disposable tmpfs profile."""
import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile

from run_persistent_ui_probe import extract_candidate, run_child
from verify_owner_reading import FRAME, RUNNER_ERRORS, decode_envelope, validate_cookies
from check_owner_full_book import inspect_full_book,FullBookIncomplete
from verify_reader_context import project as reader_context, ContextError


def check_installed(candidate,profile):
    files=0
    with zipfile.ZipFile(candidate) as archive:
        for item in archive.infolist():
            if item.is_dir():continue
            installed=profile/'plugins'/item.filename
            if installed.is_symlink() or installed.read_bytes()!=archive.read(item):raise ValueError('stage_unverified')
            files+=1
    if not 1<=files<=1000:raise ValueError('stage_unverified')
    return {'files':files,'bytes_match':True}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--width', type=int, default=600)
    parser.add_argument('--height', type=int, default=800)
    parser.add_argument('--dpi', type=int, default=167)
    addons = parser.add_mutually_exclusive_group()
    addons.add_argument('--cb-reading', action='store_true')
    addons.add_argument('--cb-full-book', action='store_true')
    parser.add_argument('--cb-sync-limit',action='store_true')
    parser.add_argument('--cb-single-page',action='store_true')
    parser.add_argument('--diagnostic-read-pacing', action='store_true')
    addons.add_argument('--annotations', action='store_true')
    parser.add_argument('--thought-replies-reader', action='store_true', help='Verify one public thought reply in ReaderUI')
    addons.add_argument('--annotation-recovery', action='store_true')
    addons.add_argument('--progress-preview', action='store_true')
    addons.add_argument('--progress-roundtrip', action='store_true')
    addons.add_argument('--source-upload-preview', action='store_true')
    addons.add_argument('--native-source-excerpt', action='store_true')
    parser.add_argument('--native-routing-preview', action='store_true')
    addons.add_argument('--selection-thought-preview', action='store_true')
    parser.add_argument('--mock-port',type=int)
    parser.add_argument('--cb-mock-port',type=int,help='Synthetic CB reading fixture only')
    parser.add_argument('--synthetic-txt-retry',action='store_true')
    parser.add_argument('--missing-resume',action='store_true')
    parser.add_argument('--resume-warning',action='store_true')
    parser.add_argument('--reader-estimate',action='store_true')
    parser.add_argument('--full-cache-status',action='store_true')
    parser.add_argument('--reader-neighbor',action='store_true')
    parser.add_argument('--reader-typography',action='store_true')
    parser.add_argument('--reader-margins',action='store_true')
    parser.add_argument('--reader-display',action='store_true')
    parser.add_argument('--off-shelf-home',action='store_true')
    parser.add_argument('--off-shelf-store',action='store_true')
    parser.add_argument('--off-shelf-cover',action='store_true')
    parser.add_argument('--off-shelf-marks',action='store_true')
    parser.add_argument('--off-shelf-mock-port',type=int)
    parser.add_argument('--resume-mock-port',type=int,help='Synthetic missing-resume fixture only')
    args = parser.parse_args(argv)
    if args.thought_replies_reader and not args.annotations:
        parser.error('--thought-replies-reader requires --annotations')
    if args.off_shelf_store and not args.off_shelf_home:parser.error('--off-shelf-store requires --off-shelf-home')
    if args.off_shelf_cover and not args.off_shelf_store:parser.error('--off-shelf-cover requires --off-shelf-store')
    if args.off_shelf_marks and not args.off_shelf_store:parser.error('--off-shelf-marks requires --off-shelf-store')
    if args.off_shelf_home and (args.cb_reading or args.cb_full_book or args.annotations or args.annotation_recovery
            or args.progress_preview or args.progress_roundtrip or args.source_upload_preview or args.native_source_excerpt
            or args.selection_thought_preview or args.missing_resume or args.mock_port is not None or args.cb_mock_port is not None):
        parser.error('--off-shelf-home requires the ordinary standalone reading fixture')
    if args.off_shelf_mock_port is not None and (not args.off_shelf_home or not 1<=args.off_shelf_mock_port<=65535):
        parser.error('--off-shelf-mock-port requires off-shelf home mode and a valid loopback port')
    if args.resume_warning and not args.missing_resume:parser.error('--resume-warning requires --missing-resume')
    if args.reader_estimate and (args.cb_reading or args.cb_full_book or args.annotations or args.annotation_recovery
            or args.progress_preview or args.progress_roundtrip or args.source_upload_preview or args.native_source_excerpt
            or args.selection_thought_preview or args.off_shelf_home):
        parser.error('--reader-estimate requires an ordinary single-chapter reader')
    if args.reader_neighbor and (not args.reader_estimate or args.missing_resume and args.resume_mock_port is None):
        parser.error('--reader-neighbor requires --reader-estimate; missing-resume is synthetic only')
    if args.reader_typography and (args.reader_estimate or args.cb_reading or args.cb_full_book or args.annotations or args.annotation_recovery
            or args.progress_preview or args.progress_roundtrip or args.source_upload_preview or args.native_source_excerpt
            or args.selection_thought_preview or args.off_shelf_home):
        parser.error('--reader-typography requires an ordinary single-chapter reader')
    if args.reader_margins and (args.reader_estimate or args.reader_typography or args.cb_reading or args.cb_full_book or args.annotations or args.annotation_recovery
            or args.progress_preview or args.progress_roundtrip or args.source_upload_preview or args.native_source_excerpt
            or args.selection_thought_preview or args.off_shelf_home):
        parser.error('--reader-margins requires an ordinary single-chapter reader')
    if args.reader_display and (args.reader_margins or args.reader_estimate or args.reader_typography or args.cb_reading or args.cb_full_book or args.annotations or args.annotation_recovery
            or args.progress_preview or args.progress_roundtrip or args.source_upload_preview or args.native_source_excerpt
            or args.selection_thought_preview or args.off_shelf_home):
        parser.error('--reader-display requires an ordinary single-chapter reader')
    if args.missing_resume and (args.cb_reading or args.cb_full_book or args.annotations or args.annotation_recovery
            or args.progress_preview or args.progress_roundtrip or args.source_upload_preview or args.native_source_excerpt
            or args.selection_thought_preview or args.mock_port is not None or args.cb_mock_port is not None):
        parser.error('--missing-resume uses its own standalone reader fixture')
    if args.resume_mock_port is not None and (not args.missing_resume or not 1<=args.resume_mock_port<=65535):
        parser.error('--resume-mock-port requires missing-resume mode and a valid loopback port')
    if args.cb_sync_limit and not args.cb_reading:parser.error('--cb-sync-limit requires --cb-reading')
    if args.cb_single_page and (not args.cb_reading or args.cb_sync_limit):parser.error('--cb-single-page requires single CB reading')
    if args.native_routing_preview and not args.native_source_excerpt:parser.error('native routing preview requires TXT excerpt mode')
    if args.mock_port is not None and (not args.selection_thought_preview or not 1<=args.mock_port<=65535):
        parser.error('--mock-port requires --selection-thought-preview and a valid loopback port')
    if args.cb_mock_port is not None and (not args.cb_reading or not 1<=args.cb_mock_port<=65535 or args.mock_port is not None):
        parser.error('--cb-mock-port requires CB reading and a valid loopback port')
    if args.synthetic_txt_retry and (not args.cb_reading or args.cb_mock_port is None or args.cb_full_book or args.cb_single_page):
        parser.error('--synthetic-txt-retry requires a single synthetic CB fixture')
    if args.diagnostic_read_pacing and not args.cb_full_book:
        parser.error('--diagnostic-read-pacing requires --cb-full-book')
    runtime = args.koreader.resolve()
    if sys.platform != 'linux' or not (runtime / 'luajit').is_file() or min(args.width, args.height, args.dpi) < 1:
        parser.error('requires Linux, a built runtime and positive display dimensions')
    if not any(line.split()[1:3] == ['/dev/shm', 'tmpfs'] for line in Path('/proc/mounts').read_text().splitlines()):
        parser.error('/dev/shm must be tmpfs')
    report = dict(result='UNVERIFIED', tmpfs_profile=True, profile_removed=False, stages=[], runner_error='none')
    root, cookies = None, {}
    recovery_private = []
    progress_private = None
    candidate_private = []
    selection_private = []
    try:
        raw = sys.stdin.buffer.read(256 * 1024 + 1)
        if len(raw) > 256 * 1024:
            raise ValueError('input_limit')
        payload = json.loads(raw)
        if args.full_cache_status != (payload.get('full_cache_status_probe') is True):raise ValueError('input_limit')
        if args.full_cache_status and ('full_manifest' not in payload or args.cb_reading and not args.cb_full_book):
            raise ValueError('input_limit')
        if args.reader_estimate != (payload.get('reader_estimate_probe') is True):raise ValueError('input_limit')
        if args.reader_neighbor != ('reader_neighbor' in payload):raise ValueError('input_limit')
        if args.reader_neighbor:
            import re
            neighbor=payload['reader_neighbor']
            if (not isinstance(neighbor,dict) or set(neighbor)!={'uid','direction','raw_sha256'}
                    or not isinstance(neighbor['uid'],str) or not re.fullmatch(r'[1-9]\d{0,19}',neighbor['uid'])
                    or neighbor['uid']==payload.get('chapter_uid') or type(neighbor['direction']) is not int
                    or neighbor['direction'] not in (-1,1) or not isinstance(neighbor['raw_sha256'],str)
                    or not re.fullmatch(r'[0-9a-f]{64}',neighbor['raw_sha256'])):raise ValueError('input_limit')
        if args.reader_typography != (payload.get('reader_typography_probe') is True):raise ValueError('input_limit')
        if args.reader_margins != (payload.get('reader_margins_probe') is True):raise ValueError('input_limit')
        if args.reader_display != (payload.get('reader_display_probe') is True):raise ValueError('input_limit')
        if args.off_shelf_home != (payload.get('off_shelf_home') is True):raise ValueError('input_limit')
        if args.off_shelf_store != (payload.get('off_shelf_store') is True):raise ValueError('input_limit')
        if args.off_shelf_cover != (payload.get('off_shelf_cover') is True):raise ValueError('input_limit')
        if args.off_shelf_marks != (payload.get('off_shelf_marks') is True):raise ValueError('input_limit')
        if args.off_shelf_marks:
            from my_cloud_marks_model import project
            expected=payload.get('native_marks_expected')
            if (not isinstance(expected,dict) or len(json.dumps(expected,ensure_ascii=False).encode())>128*1024
                    or project(expected,payload['book_id'],payload['vid'],1)!=expected):raise ValueError('input_limit')
        elif 'native_marks_expected' in payload:raise ValueError('input_limit')
        if payload.get('off_shelf_mock_port')!=args.off_shelf_mock_port:raise ValueError('input_limit')
        if args.off_shelf_mock_port is not None and (payload.get('vid')!='900000' or payload.get('book_id')!='900001'
                or payload.get('cookies')!={'wr_vid':'900000','wr_skey':'mock_key'}):raise ValueError('input_limit')
        if args.off_shelf_home:
            row=payload.get('off_shelf_row')
            if (not isinstance(row,dict) or set(row)!={'bookId','title','author'} or row['bookId']!=payload.get('book_id')
                    or not isinstance(row['title'],str) or not 0<len(row['title'].encode())<=1024
                    or not isinstance(row['author'],str) or len(row['author'].encode())>1024
                    or payload['book_id'] in payload.get('shelf_ids',[]) or 'full_manifest' in payload):
                raise ValueError('input_limit')
        if (not (payload.get('missing_resume_probe') is None or payload.get('missing_resume_probe') is True)
                or args.missing_resume != (payload.get('missing_resume_probe') is True)
                or payload.get('resume_mock_port')!=args.resume_mock_port):
            raise ValueError('input_limit')
        if (not (payload.get('resume_warning_probe') is None or payload.get('resume_warning_probe') is True)
                or args.resume_warning != (payload.get('resume_warning_probe') is True)):
            raise ValueError('input_limit')
        if args.resume_mock_port is not None and (payload.get('vid')!='900000' or payload.get('book_id')!='900001'
                or payload.get('cookies')!={'wr_vid':'900000','wr_skey':'mock_key'}):raise ValueError('input_limit')
        if payload.get('cb_mock_port')!=args.cb_mock_port:raise ValueError('input_limit')
        if args.cb_mock_port is not None and (payload.get('vid')!='900000' or payload.get('book_id')!='CB_SyntheticResume'
                or payload.get('cookies')!={'wr_vid':'900000','wr_skey':'mock_key'}):raise ValueError('input_limit')
        if args.native_routing_preview != (payload.get('native_routing_preview') is True):raise ValueError('input_limit')
        if args.native_routing_preview or args.off_shelf_store:
            from verify_eink_renewal import validate_credentials
            validate_credentials(payload.get('native_grant'))
            if payload['native_grant']['vid']!=payload['vid']:raise ValueError('input_limit')
            if args.native_routing_preview and not isinstance(payload.get('expected_native_remote'),dict):raise ValueError('input_limit')
            if args.off_shelf_store and (not isinstance(payload.get('store_search_keyword'),str)
                    or not 0<len(payload['store_search_keyword'].encode())<=512):raise ValueError('input_limit')
            if args.off_shelf_mock_port is not None and (payload['native_grant']['accessToken']!='mock-native-access'
                    or payload['native_grant']['refreshToken']!='mock-native-refresh'):raise ValueError('input_limit')
        elif 'native_grant' in payload:raise ValueError('input_limit')
        if payload.get('selection_mock_port')!=args.mock_port:
            raise ValueError('input_limit')
        if args.mock_port is not None:
            grant=payload.get('selection_preview',{}).get('credentials',{})
            if (payload.get('vid')!='900000' or payload.get('book_id')!='900001'
                    or payload.get('cookies')!={'wr_vid':'900000','wr_skey':'mock_key'}
                    or grant.get('accessToken')!='mock-native-access' or grant.get('refreshToken')!='mock-native-refresh'):
                raise ValueError('input_limit')
        if args.diagnostic_read_pacing != (payload.get('diagnostic_read_pacing') is True):
            raise ValueError('input_limit')
        cb_reading=args.cb_reading or args.cb_full_book
        if (cb_reading != (payload.get('cb_reading') is True) or args.cb_reading and 'full_manifest' in payload
                or args.cb_full_book != (payload.get('cb_full_book') is True)
                or args.cb_full_book and 'full_manifest' not in payload):
            raise ValueError('input_limit')
        if args.cb_sync_limit != (payload.get('cb_sync_limit_preview') is True):raise ValueError('input_limit')
        if args.cb_single_page != (payload.get('cb_single_page') is True):raise ValueError('input_limit')
        decoder = decode_envelope
        if args.cb_sync_limit:
            from cb_sync_limit_contract import decode_envelope as decoder
        if args.annotations:
            if args.thought_replies_reader:
                from owner_thought_replies_contract import decode
                if not isinstance(payload.get('annotations', {}).get('reply_check'), dict): raise ValueError('input_limit')
            else:
                from owner_annotation_contract import decode
                if 'reply_check' in payload.get('annotations', {}): raise ValueError('input_limit')
            decoder = decode
        if args.annotation_recovery:
            from owner_recovery_contract import decode
            decoder = decode
        if args.progress_preview:
            from owner_progress_preview_contract import decode
            decoder = decode
        if args.progress_roundtrip:
            from owner_progress_roundtrip_contract import decode
            decoder = decode
        if args.source_upload_preview:
            from owner_source_candidate_contract import decode
            decoder = decode
        if args.native_source_excerpt:
            from owner_native_excerpt_contract import decode
            decoder = decode
        if args.selection_thought_preview:
            from owner_selection_preview import decode,validate_input
            validate_input(payload)
            decoder = decode
        has_annotations = args.annotations or args.annotation_recovery
        if has_annotations != ('annotations' in payload) or has_annotations and 'full_manifest' in payload:
            raise ValueError('input_limit')
        if args.progress_preview != ('progress_preview' in payload) or args.progress_preview and ('full_manifest' in payload or has_annotations):
            raise ValueError('input_limit')
        if args.progress_roundtrip != ('progress_roundtrip' in payload) or args.progress_roundtrip and ('full_manifest' in payload or has_annotations):
            raise ValueError('input_limit')
        if args.source_upload_preview != ('source_upload_preview' in payload) or args.source_upload_preview and ('full_manifest' in payload or has_annotations):
            raise ValueError('input_limit')
        if args.native_source_excerpt != ('native_source_excerpt' in payload) or args.native_source_excerpt and (
                payload['native_source_excerpt'] is not True or payload.get('source_format')!='web_txt' or 'full_manifest' in payload or has_annotations):
            raise ValueError('input_limit')
        if args.selection_thought_preview != ('selection_preview' in payload) or args.selection_thought_preview and ('full_manifest' in payload or has_annotations):
            raise ValueError('input_limit')
        full_chapters = len(payload['full_manifest']) if 'full_manifest' in payload else 1
        if args.missing_resume and (full_chapters!=1 or payload.get('source_format')!='web_xhtml'):
            raise ValueError('input_limit')
        if not 1 <= full_chapters <= (128 if args.cb_full_book else 32) or args.cb_full_book and full_chapters < 2:
            raise ValueError('input_limit')
        if full_chapters > 1:
            report['full_book'] = None
        cookies = validate_cookies(payload['cookies'], payload['vid'])
        with tempfile.TemporaryDirectory(prefix='weread-reading-', dir='/dev/shm') as temporary:
            root = Path(temporary)
            profile, xdg = root / 'profile', root / 'xdg'
            (profile / 'plugins').mkdir(parents=True)
            xdg.mkdir(mode=0o700)
            extract_candidate(args.candidate, profile / 'plugins')
            env = dict(os.environ, KO_HOME=str(profile), XDG_RUNTIME_DIR=str(xdg),
                       EMULATE_READER='1', EMULATE_BW_SCREEN='1', EMULATE_BB_TYPE='BB8',
                       EMULATE_READER_W=str(args.width), EMULATE_READER_H=str(args.height),
                       EMULATE_READER_DPI=str(args.dpi))
            env.pop('WEREAD_SYNTHETIC_TXT_RETRY', None)
            if args.synthetic_txt_retry:env['WEREAD_SYNTHETIC_TXT_RETRY']='1'
            probe = Path(__file__).resolve().parent.parent / 'spec/koreader/owner_reading_probe.lua'
            full_hash = None
            for mode in (('live',) if args.progress_preview or args.progress_roundtrip else ('live', 'reopen')):
                payload['cookies'] = cookies
                command = [str(runtime / 'luajit'), str(probe), mode]
                if args.cb_sync_limit:
                    command.append(str(probe.with_name('owner_cb_sync_limit_case.lua')))
                if args.annotations:
                    command.append(str(probe.with_name('owner_thought_replies_case.lua' if args.thought_replies_reader
                                                       else 'owner_annotations_case.lua')))
                if args.annotation_recovery:
                    command.append(str(probe.with_name('owner_expired_annotations_case.lua')))
                if args.progress_preview:
                    command.append(str(probe.with_name('owner_progress_preview_case.lua')))
                if args.progress_roundtrip:
                    command.append(str(probe.with_name('owner_progress_roundtrip_case.lua')))
                if args.source_upload_preview:
                    command.append(str(probe.with_name('owner_source_candidate_case.lua')))
                if args.native_source_excerpt:
                    command.append(str(probe.with_name('owner_native_excerpt_case.lua')))
                if args.selection_thought_preview:
                    command.append(str(probe.with_name('owner_selection_preview_case.lua')))
                code, out, repaint = run_child(command, env,
                                               json.dumps(payload, ensure_ascii=False).encode(), runtime,
                                               timeout=900 if args.cb_full_book and mode=='live' else 600 if full_chapters > 1 and mode == 'live' else 150)
                envelope = decoder(out, payload['vid'], mode=mode, full_chapters=full_chapters,
                                   **({'cb_reading': True,'cb_full_book':args.cb_full_book} if cb_reading else {}),
                                   **({'single_page': True} if args.cb_single_page else {}),
                                   **({'synthetic_txt_retry': True} if args.synthetic_txt_retry else {}),
                                   **({'missing_resume': True} if args.missing_resume else {}),
                                   **({'resume_warning': True} if args.resume_warning else {}),
                                   **({'reader_estimate': True} if args.reader_estimate else {}),
                                   **({'reader_neighbor': True} if args.reader_neighbor else {}),
                                   **({'full_cache_status': True} if args.full_cache_status else {}),
                                   **({'reader_typography': True} if args.reader_typography else {}),
                                   **({'reader_margins': True} if args.reader_margins else {}),
                                   **({'reader_display': True} if args.reader_display else {}),
                                   **({'off_shelf_home': True} if args.off_shelf_home else {}),
                                   **({'off_shelf_store': True} if args.off_shelf_store else {}),
                                   **({'off_shelf_cover': True} if args.off_shelf_cover else {}),
                                   **({'off_shelf_marks': True} if args.off_shelf_marks else {}))
                cookies = envelope['cookies']
                if args.progress_preview or args.progress_roundtrip: progress_private = envelope['progress_private']
                if args.source_upload_preview or args.native_source_excerpt: candidate_private.append(envelope['candidate_private'])
                if args.selection_thought_preview: selection_private.append(envelope['selection_private'])
                if args.annotation_recovery:
                    private = envelope['recovery_private']
                    recovery_private.append(private)
                    if mode == 'live' and private['recovery']['saved_new_grant']:
                        payload['annotations']['credentials'] = private['credentials']
                        payload['annotations']['permit_renewal'] = False
                        payload['annotations']['intent_digest'] = ''
                        if private['model'] is not None: payload['annotations'].update(private['model'])
                private_html=envelope.pop('rejected_html',None)
                if private_html:
                    comparison=dict(checked=True,valid=False,reason='other')
                    try:
                        reader_context(dict(book_id=payload['book_id']),base64.b64decode(private_html,validate=True).decode())
                        comparison.update(valid=True,reason='none')
                    except ContextError as exc:
                        reason=str(exc).removeprefix('reader_context/')
                        if reason in ('invalid_identity','invalid_response','book_mismatch','invalid_session'):
                            comparison['reason']=reason
                    envelope['report']['reader_python_projection']=comparison
                    private_html=None
                report['stages'].append(envelope['report'])
                if code or repaint or envelope['report']['result'] != 'PASS':
                    raise ValueError('stage_unverified')
                if args.progress_roundtrip and envelope['report']['progress_roundtrip']['result']!='PASS':
                    raise ValueError('experiment_unverified')
                if full_chapters > 1:
                    inspected, current_hash = inspect_full_book(profile, payload)
                    if mode == 'reopen' and current_hash != full_hash:
                        raise ValueError('stage_unverified')
                    full_hash = current_hash
                    inspected['fresh_offline_package_identical'] = mode == 'reopen'
                    report['full_book'] = inspected
            if args.selection_thought_preview or args.native_source_excerpt or args.cb_sync_limit:
                report['installed_package']=check_installed(args.candidate,profile)
            report['result'] = 'PASS'
    except subprocess.TimeoutExpired:
        report['runner_error'] = 'child_timeout'
    except Exception as exc:
        if args.off_shelf_mock_port is not None and os.environ.get('WEREAD_SYNTHETIC_DEBUG')=='1':
            import traceback
            traceback.print_exc(file=sys.stderr)
            if 'out' in locals() and out.count(FRAME)==1:
                try:sys.stderr.write('SYNTHETIC_STAGE='+json.dumps(json.loads(out.split(FRAME)[1]).get('report'))+'\n')
                except Exception:pass
        if isinstance(exc,FullBookIncomplete):report['full_book']=exc.summary
        report['runner_error'] = str(exc) if str(exc) in RUNNER_ERRORS else 'runner_exception'
        if args.progress_preview:
            from owner_progress_preview_contract import ERRORS
            if str(exc) in ERRORS:report['runner_error']=str(exc)
        if args.progress_roundtrip:
            from owner_progress_roundtrip_contract import ERRORS
            if str(exc) in ERRORS:report['runner_error']=str(exc)
        if args.source_upload_preview:
            from owner_source_candidate_contract import ERRORS
            if str(exc) in ERRORS:report['runner_error']=str(exc)
    finally:
        report['profile_removed'] = root is not None and not root.exists()
    # This private envelope is consumed only by the captured host verifier pipe.
    envelope = dict(report=report, cookies=cookies)
    if args.annotation_recovery: envelope['recovery_private'] = recovery_private
    if args.progress_preview or args.progress_roundtrip: envelope['progress_private'] = progress_private
    if args.source_upload_preview or args.native_source_excerpt: envelope['candidate_private'] = candidate_private
    if args.selection_thought_preview: envelope['selection_private'] = selection_private
    sys.stdout.buffer.write(FRAME + json.dumps(envelope).encode() + b'\n')
    return 0 if report['result'] == 'PASS' and report['profile_removed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
