#!/usr/bin/env python3
"""Render a synthetic native-source EPUB and reopen it offline in KOReader."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parent.parent


def run(runtime):
    with tempfile.TemporaryDirectory(prefix='weread-native-render-', dir='/dev/shm') as root:
        for width, height, dpi in ((600, 800, 167), (1264, 1680, 300)):
            home = Path(root) / str(width)
            home.mkdir()
            xdg = home / 'xdg'
            xdg.mkdir(mode=0o700)
            env = dict(os.environ, KO_HOME=str(home), XDG_RUNTIME_DIR=str(xdg), LD_LIBRARY_PATH=str(runtime/'libs'),
                       SDL_VIDEODRIVER='dummy', EMULATE_READER='1', EMULATE_BW_SCREEN='1', EMULATE_BB_TYPE='BB8',
                       EMULATE_READER_W=str(width), EMULATE_READER_H=str(height), EMULATE_READER_DPI=str(dpi))
            for mode in ('create', 'offline'):
                child = subprocess.run([str(runtime/'luajit'), str(REPO/'spec/koreader/native_chapter_render_probe.lua'),
                                        str(REPO), mode], cwd=runtime, env=env, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, timeout=90)
                if child.returncode or b'PASS: native resource EPUB' not in child.stdout:
                    raise RuntimeError(f'native resource rendering {width} {mode} failed: '
                                       + child.stdout[-1500:].decode('utf8', 'replace'))
            print(f'PASS: native resource EPUB rendered and reopened offline {width}x{height}')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True)
    run(parser.parse_args().koreader.resolve())


if __name__=='__main__':
    main()
