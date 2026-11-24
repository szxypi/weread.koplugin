#!/usr/bin/env python3
"""Exercise cancellation and restart of real KOReader subprocess pipes."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

from run_persistent_ui_probe import extract_candidate, run_child

FRAME = b'\nWEREAD_WORKER_CANCEL='


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    runtime = args.koreader.resolve()
    with tempfile.TemporaryDirectory(prefix='weread-worker-cancel-', dir='/dev/shm') as temporary:
        root = Path(temporary)
        profile = root / 'profile'
        (profile / 'plugins').mkdir(parents=True)
        xdg = root / 'xdg'
        xdg.mkdir(mode=0o700)
        candidate = root / 'candidate.zip'
        subprocess.run(['bash', str(repo / 'scripts/package_release.sh'), str(candidate)], check=True, capture_output=True)
        extract_candidate(candidate, profile / 'plugins')
        env = dict(os.environ, KO_HOME=str(profile), XDG_RUNTIME_DIR=str(xdg), SDL_VIDEODRIVER='dummy',
                   EMULATE_READER='1', EMULATE_BW_SCREEN='1', EMULATE_BB_TYPE='BB8',
                   EMULATE_READER_W='1264', EMULATE_READER_H='1680', EMULATE_READER_DPI='300')
        code, output, repaint = run_child([str(runtime / 'luajit'),
            str(repo / 'spec/koreader/memory_worker_cancel_probe.lua')], env, b'', runtime, timeout=60)
        if code or repaint or output.count(FRAME) != 1:
            raise ValueError('worker cancellation probe failed')
        result = json.loads(output.split(FRAME)[1])
        if (result['result'] != 'PASS' or result['modes'] != 2 or not result['restarted']
                or result['descriptors_before'] != result['descriptors_after']):
            raise ValueError('worker cancellation verification failed')
        print(json.dumps(result))


if __name__ == '__main__':
    main()
