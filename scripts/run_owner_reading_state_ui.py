#!/usr/bin/env python3
"""Packaged KOReader owner UI in tmpfs; private input remains on pipes."""
import argparse
import json
import os
from pathlib import Path
import resource
import subprocess
import sys
import tempfile

from run_persistent_ui_probe import extract_candidate, run_child

FRAME = b'\nWEREAD_OWNER_READING_STATE='


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--width', type=int, default=600)
    parser.add_argument('--height', type=int, default=800)
    parser.add_argument('--dpi', type=int, default=167)
    args = parser.parse_args()
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    raw = b''
    result = {'error': 'ui_runner_failed'}
    stage = 'runner'
    try:
        if sys.platform != 'linux' or not any(line.split()[1:3] == ['/dev/shm', 'tmpfs']
                                               for line in Path('/proc/mounts').read_text().splitlines()):
            raise ValueError('tmpfs_required')
        raw = os.read(0, 2 * 1024 * 1024 + 1)
        while len(raw) <= 2 * 1024 * 1024:
            chunk = os.read(0, min(65536, 2 * 1024 * 1024 + 1 - len(raw)))
            if not chunk:
                break
            raw += chunk
        if len(raw) > 2 * 1024 * 1024:
            raise ValueError('input_limit')
        repo = Path(__file__).resolve().parent.parent
        with tempfile.TemporaryDirectory(prefix='weread-reading-owner-', dir='/dev/shm') as temporary:
            root = Path(temporary)
            profile = root / 'profile'
            (profile / 'plugins').mkdir(parents=True)
            xdg = root / 'xdg'
            xdg.mkdir(mode=0o700)
            candidate = root / 'candidate.zip'
            subprocess.run(['bash', str(repo / 'scripts/package_release.sh'), str(candidate)], check=True, capture_output=True)
            extract_candidate(candidate, profile / 'plugins')
            env = dict(os.environ, KO_HOME=str(profile), XDG_RUNTIME_DIR=str(xdg), EMULATE_READER='1',
                       EMULATE_BW_SCREEN='1', EMULATE_BB_TYPE='BB8', EMULATE_READER_W=str(args.width),
                       EMULATE_READER_H=str(args.height), EMULATE_READER_DPI=str(args.dpi))
            code, out, repaint = run_child([str(args.koreader.resolve() / 'luajit'),
                str(repo / 'spec/koreader/owner_reading_state_ui_probe.lua')], env, raw,
                args.koreader.resolve(), timeout=120)
            raw = b''
            if len(out) > 65536 or out.count(FRAME) != 1:
                raise ValueError('ui_probe')
            value = json.loads(out.split(FRAME)[1])
            if code or repaint:
                if value.get('stage') in ('input', 'menu', 'result', 'audit'):
                    stage = value['stage']
                raise ValueError('ui_probe')
            if set(value) != {'model', 'native', 'requests', 'ui'} or value['ui'] is not True:
                raise ValueError('ui_result')
            result = value
        if Path(temporary).exists():
            raise ValueError('profile_cleanup')
    except Exception:
        result = {'error': 'ui_runner_failed', 'stage': stage}
    finally:
        raw = b''
    sys.stdout.write(FRAME.decode() + json.dumps(result) + '\n')
    return 0 if result.get('ui') is True else 1


if __name__ == '__main__':
    raise SystemExit(main())
