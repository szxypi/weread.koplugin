#!/usr/bin/env python3
"""Exercise the installed native reader and home across offline processes."""
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

REPO = Path(__file__).resolve().parent.parent
fixture.body = lambda uid: '<html><body>' + ''.join(
    f'<p>Chapter {uid}, synthetic paragraph {index} for pagination.</p>' for index in range(100)) + '</body></html>'


def frame(child, marker):
    if child.returncode:
        raise AssertionError(child.stdout[-5000:] + child.stderr[-5000:])
    lines = [line for line in child.stdout.splitlines() if line.startswith(marker)]
    assert len(lines) == 1
    return json.loads(lines[0][len(marker):])


def run(runtime):
    server = ThreadingHTTPServer(('127.0.0.1', 0), fixture.Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='weread-native-home-package-', dir='/dev/shm') as package:
            candidate = Path(package) / 'candidate.zip'
            subprocess.run(['bash', str(REPO/'scripts/package_release.sh'), str(candidate)], cwd=REPO,
                           check=True, capture_output=True)
            for width, height, dpi in ((600, 800, 167), (1264, 1680, 300)):
                with tempfile.TemporaryDirectory(prefix='weread-native-home-', dir='/dev/shm') as root:
                    root = Path(root)
                    for directory in ('xdg', 'settings', 'plugins'):
                        (root/directory).mkdir(mode=0o700)
                    extract_candidate(candidate, root/'plugins')
                    env = dict(os.environ, KO_HOME=str(root), XDG_RUNTIME_DIR=str(root/'xdg'),
                               LD_LIBRARY_PATH=str(runtime/'libs'), SDL_VIDEODRIVER='dummy', EMULATE_READER='1',
                               EMULATE_BW_SCREEN='1', EMULATE_BB_TYPE='BB8', EMULATE_READER_W=str(width),
                               EMULATE_READER_H=str(height), EMULATE_READER_DPI=str(dpi), WEREAD_SYNTHETIC='1')
                    server.resume = server.expired = False
                    server.resume_marker = root/'resume'
                    server.chapters = []
                    server.valid = True
                    server.leaked = False
                    server.image_requests = server.tar_requests = 0
                    payload = dict(credentials=dict(vid='12345678', accessToken='synthetic-access',
                        refreshToken='synthetic-refresh', deviceId='eink334691225'+'0'*19),
                        mock_endpoint='http://127.0.0.1:'+str(server.server_port), mode='full', plugin_profile=True)
                    child = subprocess.run([str(runtime/'luajit'), str(REPO/'spec/koreader/native_direct_nav_prepare.lua'),
                                            str(REPO)], input=json.dumps(payload), text=True, env=env, cwd=runtime,
                                           capture_output=True, timeout=150)
                    path = frame(child, 'WEREAD_DIRECT_NAV_PREPARED=')['37']
                    for mode in ('record', 'quick_home', 'quick_shelf', 'quick_store', 'reopen', 'detail', 'shelf_detail',
                                 'damage', 'detail_damage', 'shelf_damage', 'detail_closed', 'downloads',
                                 'downloads_choose', 'quick_choose', 'switch'):
                        receipt = Path(path).parent/'receipt.txt'
                        original = receipt.read_bytes() if mode in ('damage', 'detail_damage', 'shelf_damage') else None
                        if original is not None:
                            receipt.write_bytes(original+b'corrupt')
                        child = subprocess.run([str(runtime/'luajit'), str(REPO/'spec/koreader/native_home_resume_probe.lua'),
                                                str(REPO)], input=json.dumps(dict(mode=mode, path=path)), text=True,
                                               env=env, cwd=runtime, capture_output=True, timeout=150)
                        assert frame(child, 'WEREAD_NATIVE_HOME=') == dict(ok=True, mode=mode, network_blocked=True)
                        if original is not None:
                            assert receipt.read_bytes() == original+b'corrupt'
                            receipt.write_bytes(original)
                    assert server.chapters == ['37', '38'] and server.valid and not server.leaked
        print('PASS: installed native home resume, offline fresh process, both screen sizes')
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    run(parser.parse_args().koreader.resolve())
