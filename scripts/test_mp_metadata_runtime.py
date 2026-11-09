#!/usr/bin/env python3
"""Exercise MP metadata changes with a packaged native ReaderUI.

All text, notes and account data are synthetic. No real account or Keychain is
used. A second process reopens every version using its saved location.
--legacy-shared selects the explicit shared-record recovery prototype instead
of the default normal-location migration cases. It does not enable a product UI.
"""
import argparse
import os
from pathlib import Path
import subprocess
import threading

from mock_weread import MockServer, prepare

REPO = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--run-dir', type=Path, required=True)
    parser.add_argument('--width', type=int, default=600)
    parser.add_argument('--height', type=int, default=800)
    parser.add_argument('--dpi', type=int, default=167)
    parser.add_argument('--legacy-shared', action='store_true', help='exercise explicit old shared-record recovery prototype')
    args = parser.parse_args()
    if min(args.width, args.height, args.dpi) < 1:
        parser.error('display dimensions must be positive')
    root, runtime = args.run_dir.resolve(), args.koreader.resolve()
    if not (runtime / 'luajit').is_file():
        parser.error('requires a built KOReader runtime')
    server = MockServer(0)
    thread = None
    try:
        prepare(root, runtime, server.server_port, args.width, args.height, args.dpi)
        (root / 'xdg').mkdir(mode=0o700)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        environment = dict(os.environ, KO_HOME=str(root / 'profile'), WEREAD_EVIDENCE=str(root / 'evidence'),
                           XDG_RUNTIME_DIR=str(root / 'xdg'), EMULATE_READER='1', EMULATE_BW_SCREEN='1',
                           EMULATE_BB_TYPE='BB8', EMULATE_READER_W=str(args.width),
                           EMULATE_READER_H=str(args.height), EMULATE_READER_DPI=str(args.dpi))
        probe = REPO / ('spec/koreader/mp_legacy_metadata.lua' if args.legacy_shared else 'spec/koreader/mp_metadata_migration.lua')
        phases = ('recover', 'reopen') if args.legacy_shared else ('migrate', 'reopen')
        prefix = 'mp-legacy-' if args.legacy_shared else 'mp-metadata-'
        for phase in phases:
            log = root / 'evidence' / (prefix + phase + '.log')
            with log.open('w') as output:
                result = subprocess.run(['./luajit', str(probe), phase], cwd=runtime, env=environment,
                                        stdout=output, stderr=subprocess.STDOUT, timeout=180)
            if result.returncode:
                print('FAIL: ' + str(log))
                return result.returncode
            assert b'[WeRead] forceRePaint failed:' not in log.read_bytes(), 'native repaint failed'
            assert not server.events, 'offline metadata migration attempted HTTP'
            print('PASS: ' + str(log), flush=True)
        return 0
    finally:
        if thread:
            server.shutdown()
            thread.join()
        server.server_close()


if __name__ == '__main__':
    raise SystemExit(main())
