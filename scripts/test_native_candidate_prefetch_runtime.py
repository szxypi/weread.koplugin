#!/usr/bin/env python3
"""Run the production prefetch worker against bounded synthetic HTTP data."""
import argparse
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading

from test_native_candidate_downloader_runtime import SlowHandler

REPO = Path(__file__).resolve().parent.parent


def run(runtime):
    server = ThreadingHTTPServer(('127.0.0.1', 0), SlowHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        for width, height, dpi, mismatch, expired, cancel, rejected, zero_css, multi_css in ((600, 800, 167, False, False, False, False, False, False),
                                                                        (1264, 1680, 300, False, False, False, False, False, False),
                                                                        (1264, 1680, 300, False, False, False, False, True, False),
                                                                        (1264, 1680, 300, False, False, False, False, False, True),
                                                                        (600, 800, 167, True, False, False, False, False, False),
                                                                        (600, 800, 167, False, True, False, False, False, False),
                                                                        (600, 800, 167, False, False, False, True, False, False),
                                                                        (600, 800, 167, False, False, True, False, False, False)):
            with tempfile.TemporaryDirectory(prefix='weread-native-prefetch-', dir='/dev/shm') as root:
                xdg = Path(root) / 'xdg'
                xdg.mkdir(mode=0o700)
                env = dict(os.environ, KO_HOME=root, XDG_RUNTIME_DIR=str(xdg),
                           LD_LIBRARY_PATH=str(runtime / 'libs'), SDL_VIDEODRIVER='dummy',
                           EMULATE_READER='1', EMULATE_BW_SCREEN='1', EMULATE_BB_TYPE='BB8',
                           EMULATE_READER_W=str(width), EMULATE_READER_H=str(height),
                           EMULATE_READER_DPI=str(dpi), WEREAD_SYNTHETIC='1')
                payload = dict(credentials=dict(vid='12345678', accessToken='synthetic-access',
                               refreshToken='synthetic-refresh', deviceId='eink334691225' + '0' * 19),
                               mock_endpoint='http://127.0.0.1:' + str(server.server_port),
                               mismatch=mismatch, expired=expired, cancel=cancel, rejected=rejected, zero_css=zero_css, multi_css=multi_css)
                server.mode, server.paths, server.leaked = ('cancel' if cancel else 'auth' if expired else
                                                             'denied_json' if rejected else 'remote_zero_css' if zero_css
                                                             else 'remote_multi_css' if multi_css else 'remote'), [], False
                server.slow_entered = False
                server.slow_marker = Path(root) / 'slow-request'
                server.catalog_valid = server.download_valid = True
                child = subprocess.run([str(runtime / 'luajit'), str(REPO / 'spec/koreader/native_candidate_prefetch_probe.lua'),
                                        str(REPO)], input=json.dumps(payload), text=True, env=env,
                                       cwd=runtime, capture_output=True, timeout=90, check=False)
                if child.returncode:
                    raise AssertionError(child.stdout + child.stderr)
                marker = 'WEREAD_PREFETCH_RESULT='
                line = next(line for line in child.stdout.splitlines() if line.startswith(marker))
                assert json.loads(line[len(marker):]) == dict(ok=True, fallback=int(mismatch), expired=expired,
                                                               cancel=cancel, rejected=rejected)
                assert len(server.paths) == (1 if cancel else 3 if mismatch or expired or rejected else 4), server.paths
                if cancel:
                    assert server.slow_entered and server.paths == ['/book/info']
                assert not server.leaked and server.catalog_valid and server.download_valid
        print('PASS: native prefetch worker, fallback, expiry and offline KOReader render')
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--koreader', type=Path, required=True)
    run(parser.parse_args().koreader.resolve())
