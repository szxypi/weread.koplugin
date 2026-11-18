#!/usr/bin/env python3
"""Verify public native store entry and offline reopen in disposable profiles."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from run_persistent_ui_probe import extract_candidate, run_child

FRAME = b'\nWEREAD_CHART_REPORT='
TRANSFER = b'\nWEREAD_CHART_TRANSFER='


def valid_stage(stage, code, repaint, mode):
    keys = {'result', 'phase', 'mode', 'requests', 'forbidden', 'first', 'second',
            'guest', 'native_host', 'offline'}
    return (isinstance(stage, dict) and set(stage) == keys and code == 0 and repaint is False
            and stage['result'] == 'PASS' and stage['phase'] == 'complete' and stage['mode'] == mode
            and type(stage['requests']) is int and stage['requests'] == (2 if mode == 'live' else 0)
            and type(stage['forbidden']) is int and stage['forbidden'] == 0
            and all(type(stage[k]) is int and 1 <= stage[k] <= 100 for k in ('first', 'second'))
            and stage['guest'] is True and stage['native_host'] is True
            and stage['offline'] is (mode == 'reopen'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--width', type=int, default=600)
    parser.add_argument('--height', type=int, default=800)
    parser.add_argument('--dpi', type=int, default=167)
    args = parser.parse_args(); runtime = args.koreader.resolve()
    if (sys.platform != 'linux' or not (runtime / 'luajit').is_file()
            or min(args.width, args.height, args.dpi) < 1
            or not any(line.split()[1:3] == ['/dev/shm', 'tmpfs'] for line in Path('/proc/mounts').read_text().splitlines())):
        parser.error('requires Linux, tmpfs and a built KOReader runtime')
    result = {'result': 'UNVERIFIED', 'profile_removed': False, 'stages': []}
    root = None
    try:
        with tempfile.TemporaryDirectory(prefix='weread-chart-', dir='/dev/shm') as temporary:
            root = Path(temporary); profile = root / 'profile'; (profile / 'plugins').mkdir(parents=True)
            (profile / 'books').mkdir(); (root / 'xdg').mkdir(mode=0o700)
            extract_candidate(args.candidate, profile / 'plugins')
            env = dict(os.environ, KO_HOME=str(profile), XDG_RUNTIME_DIR=str(root / 'xdg'), EMULATE_READER='1',
                       EMULATE_BW_SCREEN='1', EMULATE_BB_TYPE='BB8', EMULATE_READER_W=str(args.width),
                       EMULATE_READER_H=str(args.height), EMULATE_READER_DPI=str(args.dpi))
            probe = Path(__file__).resolve().parent.parent / 'spec/koreader/public_store_entry_live.lua'
            payload = b''
            for mode in ('live', 'reopen'):
                code, out, repaint = run_child([str(runtime / 'luajit'), str(probe), mode], env, payload, runtime, timeout=100)
                if len(out) > 1024 * 1024 or out.count(FRAME) != 1:
                    raise ValueError('invalid report')
                stage = json.loads(out.split(FRAME)[1]); result['stages'].append(stage)
                if not valid_stage(stage, code, repaint, mode):
                    raise ValueError('stage failed')
                if mode == 'live':
                    if out.count(TRANSFER) != 1:
                        raise ValueError('invalid transfer')
                    transfer = json.loads(out.split(TRANSFER)[1].split(FRAME)[0])
                    if set(transfer) != {'first', 'second'}:
                        raise ValueError('invalid transfer')
                    payload = json.dumps(transfer).encode()
            result['result'] = 'PASS'
    except (OSError, ValueError, subprocess.TimeoutExpired):
        result['result'] = 'UNVERIFIED'
    finally:
        result['profile_removed'] = root is not None and not root.exists()
    print(json.dumps(result))
    return 0 if result['result'] == 'PASS' and result['profile_removed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
