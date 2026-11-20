#!/usr/bin/env python3
"""Run the opt-in native cover probe with all profile files on Linux tmpfs.

Invoke under xvfb-run through verify_shelf_covers.py --lua-command. Only a
prebuilt candidate ZIP and the installed official runtime are read from disk.
"""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--width', type=int, default=600)
    parser.add_argument('--height', type=int, default=800)
    parser.add_argument('--dpi', type=int, default=167)
    args = parser.parse_args()
    runtime = args.koreader.resolve()
    if sys.platform != 'linux' or not (runtime / 'luajit').is_file() or min(args.width, args.height, args.dpi) < 1:
        parser.error('requires Linux, a built KOReader runtime and positive display dimensions')
    # Refuse a regular-disk replacement for /dev/shm before reading private input.
    mounts = Path('/proc/mounts').read_text().splitlines()
    if not any(line.split()[1:3] == ['/dev/shm', 'tmpfs'] for line in mounts):
        parser.error('/dev/shm must be tmpfs')
    raw = sys.stdin.buffer.read(16385)
    if len(raw) > 16384:
        parser.error('input limit exceeded')
    with tempfile.TemporaryDirectory(prefix='weread-cover-', dir='/dev/shm') as temporary:
        root = Path(temporary)
        profile, xdg = root / 'profile', root / 'xdg'
        (profile / 'plugins').mkdir(parents=True)
        xdg.mkdir(mode=0o700)
        with zipfile.ZipFile(args.candidate) as package:
            for name in package.namelist():
                if not name.startswith('weread.koplugin/') or '..' in Path(name).parts:
                    parser.error('unexpected candidate layout')
            package.extractall(profile / 'plugins')
        environment = dict(os.environ, KO_HOME=str(profile),
                           WEREAD_SOURCE=str(profile / 'plugins/weread.koplugin'),
                           XDG_RUNTIME_DIR=str(xdg), EMULATE_READER='1', EMULATE_BW_SCREEN='1',
                           EMULATE_BB_TYPE='BB8', EMULATE_READER_W=str(args.width),
                           EMULATE_READER_H=str(args.height), EMULATE_READER_DPI=str(args.dpi))
        probe = Path(__file__).resolve().parent.parent / 'spec/koreader/shelf_cover_probe.lua'
        result = subprocess.run(['./luajit', str(probe)], cwd=runtime, env=environment,
                                input=raw, capture_output=True, timeout=75)
        # The parent validates a fixed result frame; never forward runtime logs.
        frame = b'\nWEREAD_COVER_RESULT='
        if result.stdout.count(frame) == 1:
            sys.stdout.buffer.write(frame + result.stdout.split(frame)[1])
        return result.returncode or int(b'[WeRead] forceRePaint failed:' in result.stdout + result.stderr)


if __name__ == '__main__':
    raise SystemExit(main())
