#!/usr/bin/env python3
"""Check packaged bookstore position across tabs and a new offline process."""
import argparse
import os
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory

from run_persistent_ui_probe import extract_candidate


def run(runtime):
    repo = Path(__file__).resolve().parent.parent
    probe = repo / 'spec/koreader/bookstore_position_probe.lua'
    with TemporaryDirectory(prefix='weread-bookstore-position-', dir='/dev/shm') as temporary:
        root = Path(temporary)
        archive = root / 'candidate.zip'
        subprocess.run(['bash', str(repo / 'scripts/package_release.sh'), str(archive)], check=True, capture_output=True)
        for width, height, dpi in ((600, 800, 167), (1264, 1680, 300)):
            for scope in ('account', 'guest', 'shared'):
                profile = root / f'{width}-{scope}'
                (profile / 'plugins').mkdir(parents=True)
                xdg = profile / 'xdg'
                xdg.mkdir(mode=0o700)
                extract_candidate(archive, profile / 'plugins')
                env = dict(os.environ, KO_HOME=str(profile), XDG_RUNTIME_DIR=str(xdg), SDL_VIDEODRIVER='dummy',
                           LD_LIBRARY_PATH=str(runtime / 'libs'), EMULATE_READER='1',
                           EMULATE_READER_W=str(width), EMULATE_READER_H=str(height), EMULATE_READER_DPI=str(dpi),
                           EMULATE_BW_SCREEN='1', EMULATE_BB_TYPE='BB8')
                stages = ('write', 'reopen', 'replace', 'reopen-stale') if scope == 'shared' else ('write', 'reopen')
                for stage in stages:
                    result = subprocess.run([str(runtime / 'luajit'), str(probe), str(repo), scope, stage],
                                            env=env, cwd=runtime, capture_output=True, text=True, timeout=90)
                    marker = f'WEREAD_BOOKSTORE_POSITION={scope}/{stage}'
                    if result.returncode or marker not in result.stdout.splitlines():
                        raise AssertionError(result.stdout[-2500:] + result.stderr[-2500:])
    print('PASS: bookstore positions across tabs and offline restart, account, guest and shared categories, both screen sizes')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', required=True, type=Path)
    run(parser.parse_args().koreader.resolve())
