#!/usr/bin/env python3
"""Exercise native-chapter time capture with installed KOReader and statistics."""
import argparse
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import test_native_full_book_runtime as fixture
from run_persistent_ui_probe import extract_candidate
from test_native_direct_navigation_runtime import frame

REPO = Path(__file__).resolve().parent.parent


def run(runtime):
    server = ThreadingHTTPServer(('127.0.0.1', 0), fixture.Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='weread-direct-time-package-', dir='/dev/shm') as package_dir:
            candidate = Path(package_dir) / 'candidate.zip'
            subprocess.run(['bash', str(REPO / 'scripts/package_release.sh'), str(candidate)],
                           cwd=REPO, check=True, capture_output=True)
            for width, height, dpi in ((600, 800, 167), (1264, 1680, 300)):
                with tempfile.TemporaryDirectory(prefix='weread-direct-time-', dir='/dev/shm') as root:
                    xdg = Path(root) / 'xdg'
                    xdg.mkdir(mode=0o700)
                    (Path(root) / 'settings').mkdir()
                    (Path(root) / 'plugins').mkdir()
                    extract_candidate(candidate, Path(root) / 'plugins')
                    env = dict(os.environ, KO_HOME=root, XDG_RUNTIME_DIR=str(xdg), LD_LIBRARY_PATH=str(runtime / 'libs'),
                               SDL_VIDEODRIVER='dummy', EMULATE_READER='1', EMULATE_BW_SCREEN='1', EMULATE_BB_TYPE='BB8',
                               EMULATE_READER_W=str(width), EMULATE_READER_H=str(height), EMULATE_READER_DPI=str(dpi),
                               WEREAD_SYNTHETIC='1')
                    credentials = dict(vid='12345678', accessToken='synthetic-access', refreshToken='synthetic-refresh',
                                       deviceId='eink334691225'+'0'*19)
                    server.resume = server.expired = False
                    server.resume_marker = Path(root) / 'resume'
                    server.chapters = []
                    server.valid = True
                    server.leaked = False
                    server.image_requests = server.tar_requests = 0
                    payload = dict(credentials=credentials, mock_endpoint='http://127.0.0.1:'+str(server.server_port),
                                   mode='full', plugin_profile=True)
                    prepared = subprocess.run([str(runtime / 'luajit'), str(REPO / 'spec/koreader/native_direct_nav_prepare.lua'), str(REPO)],
                                              input=json.dumps(payload), text=True, env=env, cwd=runtime, capture_output=True, timeout=150)
                    saved = frame(prepared, 'WEREAD_DIRECT_NAV_PREPARED=')
                    probe = subprocess.run([str(runtime / 'luajit'), str(REPO / 'spec/koreader/native_direct_offline_time_probe.lua'), str(REPO)],
                                           input=json.dumps({'first': saved['37'], 'second': saved['38']}), text=True, env=env, cwd=runtime,
                                           capture_output=True, timeout=150)
                    assert frame(probe, 'WEREAD_DIRECT_OFFLINE_TIME=') == dict(ok=True, network_blocked=True,
                        real_statistics=True, pause_resume=True, deduplicated=True, chapter_change=True,
                        account_isolated=True, transfer_disabled=True)
                    assert server.chapters == ['37', '38'] and server.valid and not server.leaked
        print('PASS: native chapter offline time capture at both KOReader sizes')
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    run(parser.parse_args().koreader.resolve())
