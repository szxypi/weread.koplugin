#!/usr/bin/env python3
"""Run one bounded native status change in a disposable tmpfs KOReader profile."""
import argparse
import json
import os
from pathlib import Path
import re
import resource
import subprocess
import sys
import tempfile
import zipfile

from run_persistent_ui_probe import extract_candidate, run_child
from verify_eink_renewal import validate_credentials

FRAME = b'\nWEREAD_OWNER_STARTED_CHANGE='


def validate_input(value, armed, mock_port=None):
    fields = {'credentials', 'book_id', 'shelf', 'progress', 'desired', 'armed'}
    if mock_port is not None: fields.add('mock_port')
    if (not isinstance(value, dict) or set(value) != fields or value.get('mock_port') != mock_port
            or value['armed'] is not armed or type(value['desired']) is not bool):
        raise ValueError('started_ui/input')
    validate_credentials(value['credentials'])
    identity = value['book_id']
    if not isinstance(identity, str) or not re.fullmatch(r'(?:[1-9][0-9]{0,19}|CB_[A-Za-z0-9_-]{1,253})', identity):
        raise ValueError('started_ui/identity')
    if mock_port is not None and (type(mock_port) is not int or not 1 <= mock_port <= 65535 or identity not in ('41', 'CB_synthetic123')
            or value['credentials'] != dict(vid='900000', accessToken='synthetic-native-access',
                refreshToken='synthetic-native-refresh', deviceId='eink334691225' + '1'*19)):
        raise ValueError('started_ui/mock')
    shelf, progress = value['shelf'], value['progress']
    if (not isinstance(shelf, dict) or not isinstance(shelf.get('books'), list) or not 1 <= len(shelf['books']) <= 5000
            or not isinstance(shelf.get('archive'), list) or not isinstance(progress, dict)
            or not isinstance(progress.get('book'), dict)):
        raise ValueError('started_ui/input')
    return value


def validate_stage(value, armed):
    required = {'result', 'phase', 'gets', 'posts', 'denied', 'files', 'preview_verified', 'credential_audit'}
    if (not isinstance(value, dict) or set(value) != required or value['result'] != 'PASS'
            or value['phase'] != 'complete' or value['preview_verified'] is not True or value['credential_audit'] is not True
            or any(type(value[key]) is not int for key in ('gets', 'posts', 'denied', 'files'))
            or not 2 <= value['gets'] <= 20 or value['posts'] != int(armed) or value['denied'] != 0
            or not 1 <= value['files'] <= 1024):
        raise ValueError('started_ui/stage')
    return value


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--armed', action='store_true')
    parser.add_argument('--mock-port', type=int)
    parser.add_argument('--width', type=int, default=600)
    parser.add_argument('--height', type=int, default=800)
    parser.add_argument('--dpi', type=int, default=167)
    args = parser.parse_args(argv)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    report = {'result': 'UNVERIFIED', 'profile_removed': False, 'installed_bytes_match': False, 'stage': None}
    temporary = None
    try:
        runtime = args.koreader.resolve()
        if (sys.platform != 'linux' or not (runtime / 'luajit').is_file()
                or not 1 <= min(args.width, args.height, args.dpi) <= max(args.width, args.height, args.dpi) <= 4096
                or not any(line.split()[1:3] == ['/dev/shm', 'tmpfs'] for line in Path('/proc/mounts').read_text().splitlines())):
            raise ValueError('started_ui/runtime')
        raw = sys.stdin.buffer.read(2 * 1024 * 1024 + 1)
        if len(raw) > 2 * 1024 * 1024:
            raise ValueError('started_ui/input')
        validate_input(json.loads(raw), args.armed, args.mock_port)
        repo = Path(__file__).resolve().parent.parent
        with tempfile.TemporaryDirectory(prefix='weread-started-owner-', dir='/dev/shm') as temporary:
            root = Path(temporary); profile = root / 'profile'; xdg = root / 'xdg'
            (profile / 'plugins').mkdir(parents=True); xdg.mkdir(mode=0o700)
            candidate = root / 'candidate.zip'
            subprocess.run(['bash', str(repo / 'scripts/package_release.sh'), str(candidate)], check=True, capture_output=True)
            extract_candidate(candidate, profile / 'plugins')
            env = dict(os.environ, KO_HOME=str(profile), XDG_RUNTIME_DIR=str(xdg), EMULATE_READER='1',
                       EMULATE_BW_SCREEN='1', EMULATE_BB_TYPE='BB8', EMULATE_READER_W=str(args.width),
                       EMULATE_READER_H=str(args.height), EMULATE_READER_DPI=str(args.dpi),
                       WEREAD_STARTED_CHANGE_ARMED='1' if args.armed else '0')
            if args.mock_port is not None: env['WEREAD_STARTED_CHANGE_MOCK'] = str(args.mock_port)
            code, out, repaint = run_child([str(runtime / 'luajit'), str(repo / 'spec/koreader/owner_reading_state_change_probe.lua')],
                                           env, raw, runtime, timeout=150)
            raw = b''
            if len(out) > 65536 or out.count(FRAME) != 1:
                raise ValueError('started_ui/frame')
            stage = json.loads(out.split(FRAME)[1])
            if code or repaint:
                if isinstance(stage, dict) and stage.get('phase') in ('input', 'menu', 'preview', 'commit', 'audit'):
                    report['phase'] = stage['phase']
                    if type(stage.get('failed_line')) is int: report['failed_line'] = stage['failed_line']
                raise ValueError('started_ui/probe')
            report['stage'] = validate_stage(stage, args.armed)
            with zipfile.ZipFile(candidate) as archive:
                for item in archive.infolist():
                    if not item.is_dir() and (profile / 'plugins' / item.filename).read_bytes() != archive.read(item):
                        raise ValueError('started_ui/installation')
            report.update(result='PASS', installed_bytes_match=True)
    except Exception:
        pass
    finally:
        report['profile_removed'] = temporary is not None and not Path(temporary).exists()
    print(FRAME.decode() + json.dumps(report, separators=(',', ':')))
    return int(report['result'] != 'PASS' or not report['profile_removed'])


if __name__ == '__main__':
    raise SystemExit(main())
