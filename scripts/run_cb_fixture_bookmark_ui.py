#!/usr/bin/env python3
"""Supervise an isolated CB fixture bookmark editor; private payload stays on pipes/tmpfs."""
import argparse
import json
import os
from pathlib import Path
import resource
import signal
import subprocess
import sys
import tempfile

from native_trial_pipe import Frames, read_initial, reply, stop, write_initial
from process_loss_runtime import enable_subreaper, kill_reader_session
from run_native_thought_trial import read_reply
from run_owner_book_search_ui import reap
from run_owner_reading_probe import check_installed
from run_persistent_ui_probe import extract_candidate


def run(payload, runtime, candidate, width, height, dpi):
    root = child = None
    report = dict(result='UNVERIFIED', profile_removed=False, installed_bytes_match=False, stage=None)
    try:
        if (sys.platform != 'linux' or not (runtime / 'luajit').is_file() or not candidate.is_file()
                or min(width, height, dpi) < 1 or max(width, height, dpi) > 4096
                or not any(line.split()[1:3] == ['/dev/shm', 'tmpfs'] for line in Path('/proc/mounts').read_text().splitlines())):
            raise ValueError('cb_bookmark/environment')
        if (not isinstance(payload, dict) or type(payload.get('armed')) is not bool
                or not isinstance(payload.get('cookies'), dict) or not isinstance(payload.get('native'), dict)):
            raise ValueError('cb_bookmark/input')
        armed = payload['armed']; token = payload.get('token')
        if not isinstance(token, str) or len(token) != 32 or any(c not in '0123456789abcdef' for c in token):
            raise ValueError('cb_bookmark/input')
        secrets = [value.encode() for mapping in (payload['cookies'], payload['native']) for key, value in mapping.items()
                   if key not in ('wr_vid', 'vid') and isinstance(value, str) and len(value) >= 8]
        if len(secrets) < 3: raise ValueError('cb_bookmark/input')
        enable_subreaper()
        with tempfile.TemporaryDirectory(prefix='weread-cb-bookmark-', dir='/dev/shm') as temporary:
            root = Path(temporary); profile = root / 'profile'; plugins = profile / 'plugins'; plugins.mkdir(parents=True)
            xdg = root / 'xdg'; xdg.mkdir(mode=0o700); extract_candidate(candidate, plugins)
            if os.environ.get('WEREAD_FIXTURE_SYNTHETIC') == '1':
                port = int(os.environ.get('WEREAD_FIXTURE_MOCK_PORT', '0'))
                if (not 1 <= port <= 65535 or payload['owner'] != '900000' or payload['book'] != 'CB_SyntheticResume'
                        or payload['native'].get('accessToken') != 'mock-native-access'
                        or payload['native'].get('refreshToken') != 'mock-native-refresh'
                        or payload['cookies'] != {'wr_vid':'900000','wr_skey':'mock_key'}):
                    raise ValueError('cb_bookmark/mock')
                (profile / 'settings').mkdir(exist_ok=True)
                (profile / 'settings/weread-environment.lua').write_text(
                    f'return {{ enabled = true, host = "127.0.0.1", port = {port} }}\n')
            installed = check_installed(candidate, profile); report['installed_bytes_match'] = installed['bytes_match']
            env = dict(os.environ, KO_HOME=str(profile), XDG_RUNTIME_DIR=str(xdg), EMULATE_READER='1', EMULATE_BW_SCREEN='1',
                       EMULATE_BB_TYPE='BB8', EMULATE_READER_W=str(width), EMULATE_READER_H=str(height), EMULATE_READER_DPI=str(dpi))
            probe = Path(__file__).resolve().parent.parent / 'spec/koreader/cb_fixture_bookmark_ui.lua'
            for reopened in ((False, True) if armed else (False,)):
                child = subprocess.Popen([str(runtime / 'luajit'), str(probe)], cwd=runtime,
                    env=env | {'WEREAD_CB_BOOKMARK_REOPEN': '1' if reopened else '0'}, stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
                try:
                    write_initial(child.stdin, payload); frames = Frames(child.stdout, token, timeout=360)
                    steps = 0
                    while True:
                        kind, value = frames.next()
                        if kind == 'RESULT': break
                        if reopened or not isinstance(value.get('seq'), int) or value['seq'] != (steps + 1 if armed else 0):
                            raise ValueError('cb_bookmark/step')
                        if not armed and steps: raise ValueError('cb_bookmark/step')
                        sys.stdout.buffer.write(b'\n' + frames.prefix + b'STEP=' + json.dumps(value,separators=(',', ':')).encode() + b'\n')
                        sys.stdout.buffer.flush(); reply(child.stdin, read_reply(sys.stdin.buffer)); steps += 1
                    status = child.wait(timeout=15)
                    expected = (dict(result='PASS',fresh_offline=True,requests=0,pending_cleared=True) if reopened else
                                dict(result='PASS',native_controls=True,source_verified=True,writes=2,denied=0,pending_cleared=True) if armed else
                                dict(result='DRY_RUN',write_blocked=True,writes=0,denied=0))
                    if value != expected or steps != (0 if reopened else 2 if armed else 1):
                        report['stage'] = {k:value[k] for k in ('result','phase','failure_line') if k in value}
                        raise ValueError('cb_bookmark/stage')
                    if status: raise ValueError('cb_bookmark/child')
                finally:
                    if child.poll() is None:
                        try: kill_reader_session(child)
                        except (ProcessLookupError, RuntimeError): pass
                    stop(child); reap(child.pid); child = None
                for path in profile.rglob('*'):
                    if path.is_file() and not path.is_symlink() and any(secret in path.read_bytes() for secret in secrets):
                        raise ValueError('cb_bookmark/credential_storage')
            report.update(result='PASS' if armed else 'DRY_RUN', native_controls=True, writes=2 if armed else 0,
                          fresh_offline=armed, credentials_not_persisted=True)
    except Exception:
        pass
    finally:
        if child is not None: stop(child)
        report['profile_removed'] = root is not None and not root.exists()
    return report


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--width',type=int,default=1264);parser.add_argument('--height',type=int,default=1680);parser.add_argument('--dpi',type=int,default=300)
    args=parser.parse_args();resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    def interrupt(_signal,_frame):raise RuntimeError('cb_bookmark/interrupted')
    signal.signal(signal.SIGTERM,interrupt)
    payload=read_initial(sys.stdin.buffer);result=run(payload,args.koreader.resolve(),args.candidate.resolve(),args.width,args.height,args.dpi)
    token=payload.get('token')
    if isinstance(token,str) and len(token)==32 and all(c in '0123456789abcdef' for c in token):
        sys.stdout.buffer.write(b'\nWEREAD_NATIVE_THOUGHT_'+token.encode()+b'_RESULT='+json.dumps(result,separators=(',',':')).encode()+b'\n')
        sys.stdout.buffer.flush()
    return int(result['result'] not in ('PASS','DRY_RUN') or not result['profile_removed'])


if __name__=='__main__':raise SystemExit(main())
