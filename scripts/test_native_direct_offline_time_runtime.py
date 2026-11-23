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
from urllib.parse import parse_qs, urlsplit
import test_native_full_book_runtime as fixture
from run_persistent_ui_probe import extract_candidate
from test_native_direct_navigation_runtime import frame

REPO = Path(__file__).resolve().parent.parent


class IndexedHandler(fixture.Handler):
    def dispatch(self):
        target = urlsplit(parse_qs(urlsplit(self.path).query).get('url', [''])[0])
        if target.hostname == 'i.weread.qq.com' and target.path == '/book/chapterInfos' and self.command == 'POST':
            server = self.server
            server.leaked |= any(key.lower() in ('vid', 'accesstoken', 'cookie') for key in self.headers)
            incoming = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
            server.valid &= incoming == dict(bookIds=['42'], synckeys=[0], updateTimes=[0], maxfreeIdx=[0])
            rows = [dict(chapterUid=int(uid), wordCount=250, price=0,
                         **({'chapterIdx': index} if server.indexed else {}))
                    for index, uid in enumerate(('37', '38', '39'), 1)]
            data = json.dumps({'data': [dict(bookId='42', updated=rows)]}).encode()
            self.send_response(200)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        super().dispatch()


def run(runtime):
    server = ThreadingHTTPServer(('127.0.0.1', 0), IndexedHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='weread-direct-time-package-', dir='/dev/shm') as package_dir:
            candidate = Path(package_dir) / 'candidate.zip'
            subprocess.run(['bash', str(REPO / 'scripts/package_release.sh'), str(candidate)],
                           cwd=REPO, check=True, capture_output=True)
            for width, height, dpi, indexed in ((600, 800, 167, True), (1264, 1680, 300, False)):
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
                    server.indexed = indexed
                    server.image_requests = server.tar_requests = 0
                    payload = dict(credentials=credentials, mock_endpoint='http://127.0.0.1:'+str(server.server_port),
                                   mode='full', plugin_profile=True)
                    prepared = subprocess.run([str(runtime / 'luajit'), str(REPO / 'spec/koreader/native_direct_nav_prepare.lua'), str(REPO)],
                                              input=json.dumps(payload), text=True, env=env, cwd=runtime, capture_output=True, timeout=150)
                    saved = frame(prepared, 'WEREAD_DIRECT_NAV_PREPARED=')
                    probe = subprocess.run([str(runtime / 'luajit'), str(REPO / 'spec/koreader/native_direct_offline_time_probe.lua'), str(REPO)],
                                           input=json.dumps({'first': saved['37'], 'second': saved['38'], 'indexed': indexed}), text=True, env=env, cwd=runtime,
                                           capture_output=True, timeout=150)
                    assert frame(probe, 'WEREAD_DIRECT_OFFLINE_TIME=') == dict(ok=True, network_blocked=True,
                        real_statistics=True, pause_resume=True, deduplicated=True, chapter_change=True, online_capture=True,
                        source_discovery=True, source_ui=True,
                        account_isolated=True, ordinary_path_isolated=True)
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
