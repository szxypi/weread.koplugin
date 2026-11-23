#!/usr/bin/env python3
"""Exercise the private owner home runner using only a loopback service."""
import argparse
import hashlib
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
from urllib.parse import parse_qs, urlsplit

import test_native_direct_position_runtime as fixture
from test_native_direct_position_runtime import BODY, Handler, REPO


class StoreHandler(Handler):
    def dispatch(self):
        target = urlsplit(parse_qs(urlsplit(self.path).query).get('url', [''])[0])
        if self.command == 'GET' and target.hostname == 'i.weread.qq.com' and target.path in ('/store/search','/book/info'):
            self.server.leaked |= any(key.lower() in ('vid','accesstoken','cookie') for key in self.headers)
            self.server.calls.append((self.command,target.hostname,target.path))
            if target.path == '/store/search':
                self.server.valid &= parse_qs(target.query) == dict(keyword=['Synthetic'],scope=['10'],count=['20'],maxIdx=['0'])
                data = dict(books=[dict(bookId='42',title='Synthetic book',author='Fixture',searchIdx=1)],hasMore=0)
            else:
                self.server.valid &= parse_qs(target.query) == dict(bookId=['42'])
                data = dict(bookId='42',title='Synthetic book',author='Fixture',format='epub',version=1)
            raw=json.dumps(data).encode()
            self.send_response(200);self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)
            return
        return super().dispatch()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--store-only', action='store_true')
    parser.add_argument('--quick-only', action='store_true')
    args = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', 0), StoreHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='weread-native-home-test-', dir='/dev/shm') as directory:
            candidate = Path(directory)/'candidate.zip'
            subprocess.run(['bash', str(REPO/'scripts/package_release.sh'), str(candidate)], cwd=REPO,
                           check=True, capture_output=True)
            cases=((600, 800, 167, False, False, False), (1264, 1680, 300, False, False, False),
                (600, 800, 167, True, False, False), (1264, 1680, 300, True, False, False),
                (600, 800, 167, True, True, False), (1264, 1680, 300, True, True, False),
                (600, 800, 167, True, True, True), (1264, 1680, 300, True, True, True))
            for width, height, dpi, full_ui, store_search, quick_search in cases:
                if args.store_only and not store_search:
                    continue
                if args.quick_only and not quick_search:
                    continue
                server.mode = 'selection_direct_overlay'
                server.calls, server.leaked, server.valid, server.review = [], False, True, None
                fixture.BODY = BODY.replace('<body>','<head><style>/* synthetic */ p{margin-left:7px}</style></head><body>') if store_search else BODY
                payload = dict(credentials=dict(vid='12345678', accessToken='synthetic-access',
                    refreshToken='synthetic-refresh', deviceId='eink334691225'+'0'*19),
                    web_cookies={'wr_vid':'12345678','wr_skey':'synthetic-web-access'},
                    book_id='42', uid='37', book_version=1, source_sha256=hashlib.sha256(fixture.BODY.encode()).hexdigest(),
                    mock_endpoint='http://127.0.0.1:'+str(server.server_port))
                command = [sys.executable, str(REPO/'scripts/run_native_direct_home_owner.py'),
                    '--koreader', str(args.koreader), '--candidate', str(candidate), '--width', str(width),
                    '--height', str(height), '--dpi', str(dpi)]
                if full_ui:
                    command.append('--full-ui')
                if store_search:
                    command.append('--store-search')
                    payload['store_search_keyword']='Synthetic'
                    payload['inline_style']='/* synthetic */ p{margin-left:7px}'
                if quick_search:
                    command.append('--quick-search')
                child = subprocess.run(command, input=json.dumps(payload).encode(),
                    capture_output=True, timeout=480)
                marker = b'\nWEREAD_DIRECT_HOME_OWNER_RUN='
                assert child.stdout.count(marker) == 1
                result = json.loads(child.stdout.split(marker, 1)[1].splitlines()[0])
                assert child.returncode == 0 and result['result'] == 'PASS', result
                assert all(result[key] is True for key in ('profile_removed','source_matches','home_record',
                    'offline_home_resume','page_restored','network_blocked','credential_file_audit','installed_bytes_match'))
                assert result.get('full_ui', False) is full_ui
                assert result.get('store_search', False) is store_search
                assert result.get('inline_style_verified', False) is store_search
                assert result.get('quick_search', False) is quick_search
                assert server.valid and not server.leaked
                assert all(path in ('/store/search','/book/info','/book/chapterInfos','/book/chapterdownload') for _,_,path in server.calls)
                assert any(path=='/store/search' for _,_,path in server.calls) is store_search
                if quick_search:
                    assert sum(path=='/store/search' for _,_,path in server.calls)==2
        print('PASS: owner home runner against synthetic service at both screen sizes')
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == '__main__':
    main()
