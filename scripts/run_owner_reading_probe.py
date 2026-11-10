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

from run_persistent_ui_probe import extract_candidate, run_child
from verify_owner_reading import FRAME, RUNNER_ERRORS, decode_envelope, validate_cookies
from check_owner_full_book import inspect_full_book,FullBookIncomplete
from verify_reader_context import project as reader_context, ContextError


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--width', type=int, default=600)
    parser.add_argument('--height', type=int, default=800)
    parser.add_argument('--dpi', type=int, default=167)
    parser.add_argument('--annotations', action='store_true')
    args = parser.parse_args(argv)
    runtime = args.koreader.resolve()
    if sys.platform != 'linux' or not (runtime / 'luajit').is_file() or min(args.width, args.height, args.dpi) < 1:
        parser.error('requires Linux, a built runtime and positive display dimensions')
    if not any(line.split()[1:3] == ['/dev/shm', 'tmpfs'] for line in Path('/proc/mounts').read_text().splitlines()):
        parser.error('/dev/shm must be tmpfs')
    report = dict(result='UNVERIFIED', tmpfs_profile=True, profile_removed=False, stages=[], runner_error='none')
    root, cookies = None, {}
    try:
        raw = sys.stdin.buffer.read(256 * 1024 + 1)
        if len(raw) > 256 * 1024:
            raise ValueError('input_limit')
        payload = json.loads(raw)
        decoder = decode_envelope
        if args.annotations:
            from owner_annotation_contract import decode
            decoder = decode
        if args.annotations != ('annotations' in payload) or args.annotations and 'full_manifest' in payload:
            raise ValueError('input_limit')
        full_chapters = len(payload['full_manifest']) if 'full_manifest' in payload else 1
        if not 1 <= full_chapters <= 32:
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
            for mode in ('live', 'reopen'):
                payload['cookies'] = cookies
                command = [str(runtime / 'luajit'), str(probe), mode]
                if args.annotations:
                    command.append(str(probe.with_name('owner_annotations_case.lua')))
                code, out, repaint = run_child(command, env,
                                               json.dumps(payload, ensure_ascii=False).encode(), runtime,
                                               timeout=600 if full_chapters > 1 and mode == 'live' else 150)
                envelope = decoder(out, payload['vid'], mode=mode, full_chapters=full_chapters)
                cookies = envelope['cookies']
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
                if full_chapters > 1:
                    inspected, current_hash = inspect_full_book(profile, payload)
                    if mode == 'reopen' and current_hash != full_hash:
                        raise ValueError('stage_unverified')
                    full_hash = current_hash
                    inspected['fresh_offline_package_identical'] = mode == 'reopen'
                    report['full_book'] = inspected
            report['result'] = 'PASS'
    except subprocess.TimeoutExpired:
        report['runner_error'] = 'child_timeout'
    except Exception as exc:
        if isinstance(exc,FullBookIncomplete):report['full_book']=exc.summary
        report['runner_error'] = str(exc) if str(exc) in RUNNER_ERRORS else 'runner_exception'
    finally:
        report['profile_removed'] = root is not None and not root.exists()
    # This private envelope is consumed only by the captured host verifier pipe.
    sys.stdout.buffer.write(FRAME + json.dumps(dict(report=report, cookies=cookies)).encode() + b'\n')
    return 0 if report['result'] == 'PASS' and report['profile_removed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
