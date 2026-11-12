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
    parser.add_argument('--diagnostic-read-pacing', action='store_true')
    addons.add_argument('--annotations', action='store_true')
    addons.add_argument('--annotation-recovery', action='store_true')
    addons.add_argument('--progress-preview', action='store_true')
    addons.add_argument('--progress-roundtrip', action='store_true')
    addons.add_argument('--source-upload-preview', action='store_true')
    addons.add_argument('--native-source-excerpt', action='store_true')
    parser.add_argument('--native-routing-preview', action='store_true')
    addons.add_argument('--selection-thought-preview', action='store_true')
    parser.add_argument('--mock-port',type=int)
    args = parser.parse_args(argv)
    if args.cb_sync_limit and not args.cb_reading:parser.error('--cb-sync-limit requires --cb-reading')
    if args.native_routing_preview and not args.native_source_excerpt:parser.error('native routing preview requires TXT excerpt mode')
    if args.mock_port is not None and (not args.selection_thought_preview or not 1<=args.mock_port<=65535):
        parser.error('--mock-port requires --selection-thought-preview and a valid loopback port')
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
        if args.native_routing_preview != (payload.get('native_routing_preview') is True):raise ValueError('input_limit')
        if args.native_routing_preview:
            from verify_eink_renewal import validate_credentials
            validate_credentials(payload.get('native_grant'))
            if payload['native_grant']['vid']!=payload['vid'] or not isinstance(payload.get('expected_native_remote'),dict):raise ValueError('input_limit')
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
        decoder = decode_envelope
        if args.cb_sync_limit:
            from cb_sync_limit_contract import decode_envelope as decoder
        if args.annotations:
            from owner_annotation_contract import decode
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
            probe = Path(__file__).resolve().parent.parent / 'spec/koreader/owner_reading_probe.lua'
            full_hash = None
            for mode in (('live',) if args.progress_preview or args.progress_roundtrip else ('live', 'reopen')):
                payload['cookies'] = cookies
                command = [str(runtime / 'luajit'), str(probe), mode]
                if args.cb_sync_limit:
                    command.append(str(probe.with_name('owner_cb_sync_limit_case.lua')))
                if args.annotations:
                    command.append(str(probe.with_name('owner_annotations_case.lua')))
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
                                   **({'cb_reading': True,'cb_full_book':args.cb_full_book} if cb_reading else {}))
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
