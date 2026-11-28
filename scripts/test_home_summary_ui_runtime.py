#!/usr/bin/env python3
"""Exercise home overview updates with synthetic local data and real SQLite."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

from run_persistent_ui_probe import extract_candidate, run_child

FRAME = b'\nWEREAD_HOME_SUMMARY_UI='


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    runtime = args.koreader.resolve()
    with tempfile.TemporaryDirectory(prefix='weread-home-summary-ui-', dir='/dev/shm') as temporary:
        root = Path(temporary)
        archive = root / 'candidate.zip'
        subprocess.run(['bash', str(repo / 'scripts/package_release.sh'), str(archive)],
                       check=True, capture_output=True)
        for width, height, dpi in ((600, 800, 167), (1264, 1680, 300)):
            profile = root / str(width)
            (profile / 'plugins').mkdir(parents=True)
            extract_candidate(archive, profile / 'plugins')
            xdg = root / f'xdg-{width}'
            xdg.mkdir(mode=0o700)
            env = dict(os.environ, KO_HOME=str(profile), XDG_RUNTIME_DIR=str(xdg), SDL_VIDEODRIVER='dummy',
                EMULATE_READER='1', EMULATE_BW_SCREEN='1', EMULATE_BB_TYPE='BB8',
                EMULATE_READER_W=str(width), EMULATE_READER_H=str(height), EMULATE_READER_DPI=str(dpi))
            code, output, repaint = run_child([str(runtime / 'luajit'),
                str(repo / 'spec/koreader/home_summary_ui_probe.lua')], env, b'', runtime, timeout=120)
            if code or repaint or output.count(FRAME) != 1:
                raise ValueError('home summary UI verification failed')
            result = json.loads(output.split(FRAME)[1])
            if result != dict(result='PASS', reads=4, goal_change=True, corruption=True,
                              account_change=True, timer_stop=True):
                raise ValueError('home summary UI result mismatch')
    print('PASS: synthetic home overview freshness and account isolation at both sizes')


if __name__ == '__main__':
    main()
