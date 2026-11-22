#!/usr/bin/env python3
"""Private duplex runner for a scoped ordinary XHTML reconnect trial.

A host broker must separately claim every write and independently verify each
receipt. Credentials and source stay in pipes or a temporary RAM filesystem.
"""
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
import zipfile

from native_trial_pipe import Frames, MAX_INPUT, read_initial, reply, write_initial
from process_loss_runtime import enable_subreaper
from run_native_thought_trial import read_reply, stop_reader
from run_persistent_ui_probe import extract_candidate


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--koreader', required=True, type=Path); p.add_argument('--candidate', required=True, type=Path)
    p.add_argument('--width', type=int, default=600); p.add_argument('--height', type=int, default=800); p.add_argument('--dpi', type=int, default=167)
    p.add_argument('--mock-port', type=int)
    p.add_argument('--dry', action='store_true')
    args = p.parse_args(argv); runtime = args.koreader.resolve(); candidate = args.candidate.resolve()
    if (sys.platform != 'linux' or not (runtime/'luajit').is_file() or not candidate.is_file()
            or not all(1 <= n <= 4096 for n in (args.width, args.height, args.dpi))
            or args.mock_port is not None and not 1 <= args.mock_port <= 65535
            or not any(line.split()[1:3] == ['/dev/shm', 'tmpfs'] for line in Path('/proc/mounts').read_text().splitlines())):
        p.error('bounded Linux runtime and tmpfs required')
    enable_subreaper(); resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    def interrupted(_signum, _frame): raise RuntimeError('ordinary_trial/interrupted')
    signal.signal(signal.SIGTERM, interrupted)
    root = child = payload = None
    report = dict(result='UNVERIFIED', profile_removed=False, installed_bytes_match=False)
    try:
        payload = read_initial(sys.stdin.buffer)
        trial = payload.get('ordinary_trial'); token = trial.get('rpc_token') if isinstance(trial, dict) else None
        cookies = payload.get('cookies')
        if (not isinstance(token, str) or not re.fullmatch(r'[a-f0-9]{32}', token) or set(trial) != {'rpc_token'}
                or payload.get('ordinary') is not True or payload.get('armed') is not (not args.dry) or payload.get('reconnect') is not True
                or payload.get('reconnect_discover') is not None or not isinstance(cookies, dict)
                or cookies.get('wr_vid') != payload.get('owner')):
            raise ValueError('ordinary_trial/scope')
        secrets = [value.encode() for key, value in cookies.items() if key != 'wr_vid' and isinstance(value, str) and len(value) >= 8]
        if not secrets: raise ValueError('ordinary_trial/scope')
        with tempfile.TemporaryDirectory(prefix='weread-ordinary-reconnect-', dir='/dev/shm') as directory:
            root = Path(directory); profile = root/'profile'; (profile/'plugins').mkdir(parents=True); (root/'xdg').mkdir(mode=0o700)
            extract_candidate(candidate, profile/'plugins')
            if args.mock_port is not None:
                (profile/'settings').mkdir(exist_ok=True)
                (profile/'settings/weread-environment.lua').write_text(
                    f'return {{ enabled = true, host = "127.0.0.1", port = {args.mock_port} }}\n')
            env = dict(os.environ, KO_HOME=str(profile), XDG_RUNTIME_DIR=str(root/'xdg'), EMULATE_READER='1', EMULATE_BW_SCREEN='1',
                       EMULATE_BB_TYPE='BB8', EMULATE_READER_W=str(args.width), EMULATE_READER_H=str(args.height),
                       EMULATE_READER_DPI=str(args.dpi), WEREAD_ORDINARY_RECONNECT_RPC='1', LD_LIBRARY_PATH=str(runtime/'libs'))
            env.pop('WEREAD_FIXTURE_SYNTHETIC', None); env.pop('WEREAD_FIXTURE_MOCK_PORT', None)
            if args.mock_port is not None:
                env['WEREAD_FIXTURE_SYNTHETIC'] = '1'; env['WEREAD_FIXTURE_MOCK_PORT'] = str(args.mock_port)
            probe = Path(__file__).resolve().parent.parent/'spec/koreader/cb_fixture_manual_ui.lua'
            for reopened in ((False,) if args.dry else (False, True)):
                child = subprocess.Popen([str(runtime/'luajit'), str(probe)], cwd=runtime,
                    env=env | {'WEREAD_FIXTURE_CB_REOPEN': '1' if reopened else '0'}, stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
                try:
                    write_initial(child.stdin, payload); frames = Frames(child.stdout, token, timeout=360, max_frame=MAX_INPUT)
                    while True:
                        kind, value = frames.next()
                        if kind == 'RESULT': break
                        if reopened: raise ValueError('ordinary_trial/reopen_request')
                        encoded=json.dumps(value,ensure_ascii=False,separators=(',', ':')).encode()
                        if len(encoded)>=MAX_INPUT-128:raise ValueError('ordinary_trial/frame')
                        sys.stdout.buffer.write(b'\n'+frames.prefix+b'STEP='+encoded+b'\n')
                        sys.stdout.buffer.flush(); reply(child.stdin, read_reply(sys.stdin.buffer))
                    expected = (dict(result='DRY_RUN', native_choice=True, write_blocked=True, writes=0, denied=1,
                                     offline_intent=True, reconnect_choice=True) if args.dry else
                                dict(result='PASS', fresh_process=True, offline=True, pending_cleared=True, journal_cleared=True, requests=0)
                                if reopened else dict(result='PASS', native_choice=True, actual_source=True, upload_confirmed=True,
                                    pending_cleared=True, journal_cleared=True, automatic_disabled=True, timer_verified=False,
                                    writes=2, denied=0, offline_intent=True, reconnect_choice=True))
                    if child.wait(timeout=15) or value != expected: raise ValueError('ordinary_trial/reader')
                finally: stop_reader(child); child = None
            with zipfile.ZipFile(candidate) as archive:
                for item in archive.infolist():
                    if item.is_dir(): continue
                    path = profile/'plugins'/item.filename
                    if path.is_symlink() or path.read_bytes() != archive.read(item): raise ValueError('ordinary_trial/candidate')
            for path in profile.rglob('*'):
                if path.is_file() and not path.is_symlink() and any(secret in path.read_bytes() for secret in secrets):
                    raise ValueError('ordinary_trial/credential_storage')
            report = dict(result='DRY_RUN', profile_removed=False, installed_bytes_match=True, native_choice=True,
                          write_blocked=True, writes=0, denied=1, credentials_not_persisted=True,
                          offline_intent=True, reconnect_choice=True) if args.dry else dict(result='PASS', profile_removed=False, installed_bytes_match=True, native_choice=True,
                          actual_source=True, upload_confirmed=True, fresh_process=True, pending_cleared=True,
                          journal_cleared=True, automatic_disabled=True, writes=2, denied=0,
                          credentials_not_persisted=True, offline_intent=True, reconnect_choice=True)
    except Exception:
        pass
    finally:
        if child is not None: stop_reader(child)
        report['profile_removed'] = root is not None and not root.exists()
    if isinstance(payload, dict):
        trial = payload.get('ordinary_trial'); token = trial.get('rpc_token') if isinstance(trial, dict) else None
        if isinstance(token, str) and re.fullmatch(r'[a-f0-9]{32}', token):
            sys.stdout.buffer.write(b'\nWEREAD_NATIVE_THOUGHT_'+token.encode()+b'_RESULT='+json.dumps(report,separators=(',', ':')).encode()+b'\n')
            sys.stdout.buffer.flush()
    return int(report['result'] != ('DRY_RUN' if args.dry else 'PASS') or not report['profile_removed'])


if __name__ == '__main__': raise SystemExit(main())
