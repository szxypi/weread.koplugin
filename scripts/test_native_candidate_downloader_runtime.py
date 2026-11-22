#!/usr/bin/env python3
"""Exercise the production chapter downloader with synthetic E-Ink HTTP data."""
import argparse
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
from urllib.parse import parse_qs, urlsplit

from test_native_chapter_source_runtime import Handler

REPO = Path(__file__).resolve().parent.parent


class SlowHandler(Handler):
    def dispatch(self):
        target = urlsplit(parse_qs(urlsplit(self.path).query).get('url', [''])[0])
        if self.server.mode == 'cancel' and target.path == '/book/info':
            self.server.slow_entered = True
            self.server.slow_marker.touch()
            time.sleep(5)
        try:
            super().dispatch()
        except (BrokenPipeError, ConnectionResetError):
            pass


def run(runtime):
    server = ThreadingHTTPServer(('127.0.0.1', 0), SlowHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        for width, height, dpi, mismatch, switch, cancel, zero_css, multi_css in ((600, 800, 167, False, False, False, False, False),
                                                     (1264, 1680, 300, False, False, False, False, False),
                                                     (1264, 1680, 300, False, False, False, True, False),
                                                     (1264, 1680, 300, False, False, False, False, True),
                                                     (600, 800, 167, True, False, False, False, False),
                                                     (600, 800, 167, False, True, False, False, False),
                                                     (600, 800, 167, False, False, True, False, False)):
            with tempfile.TemporaryDirectory(prefix='weread-candidate-', dir='/dev/shm') as root:
                xdg = Path(root) / 'xdg'
                xdg.mkdir(mode=0o700)
                env = dict(os.environ, KO_HOME=root, XDG_RUNTIME_DIR=str(xdg),
                           LD_LIBRARY_PATH=str(runtime / 'libs'), SDL_VIDEODRIVER='dummy',
                           EMULATE_READER='1', EMULATE_BW_SCREEN='1', EMULATE_BB_TYPE='BB8',
                           EMULATE_READER_W=str(width), EMULATE_READER_H=str(height),
                           EMULATE_READER_DPI=str(dpi), WEREAD_SYNTHETIC='1')
                payload = dict(credentials=dict(vid='12345678', accessToken='synthetic-access',
                               refreshToken='synthetic-refresh', deviceId='eink334691225' + '0' * 19),
                               mock_endpoint='http://127.0.0.1:' + str(server.server_port), mismatch=mismatch,
                               switch=switch, cancel=cancel, zero_css=zero_css, multi_css=multi_css)
                server.mode, server.paths, server.leaked = ('cancel' if cancel else 'remote_zero_css' if zero_css
                                                             else 'remote_multi_css' if multi_css else 'remote'), [], False
                server.slow_entered = False
                server.slow_marker = Path(root) / 'slow-request'
                server.catalog_valid = server.download_valid = True
                result = subprocess.run([str(runtime / 'luajit'), str(REPO / 'spec/koreader/native_candidate_downloader_probe.lua'),
                                         str(REPO)], input=json.dumps(payload), text=True, env=env,
                                        cwd=runtime, capture_output=True, timeout=90, check=False)
                if result.returncode:
                    raise AssertionError(result.stdout + result.stderr)
                marker = 'WEREAD_CANDIDATE_RESULT='
                line = next(line for line in result.stdout.splitlines() if line.startswith(marker))
                data = json.loads(line[len(marker):])
                if cancel:
                    assert data == dict(ok=True, cancelled=True), data
                    assert server.slow_entered and not server.paths, server.paths
                else:
                    assert data == dict(ok=True, fallback=int(mismatch), assets=int(not mismatch), stopped=switch), data
                    assert len(server.paths) == (3 if mismatch else 4), server.paths
                assert not server.leaked and server.catalog_valid and server.download_valid
        print('PASS: downloader native resources, Web-proof fallback and offline KOReader render')
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--koreader', type=Path, required=True)
    run(parser.parse_args().koreader.resolve())
