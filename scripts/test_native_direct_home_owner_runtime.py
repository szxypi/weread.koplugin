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

from test_native_direct_position_runtime import BODY, Handler, REPO


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--koreader', type=Path, required=True)
    args = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='weread-native-home-test-', dir='/dev/shm') as directory:
            candidate = Path(directory)/'candidate.zip'
            subprocess.run(['bash', str(REPO/'scripts/package_release.sh'), str(candidate)], cwd=REPO,
                           check=True, capture_output=True)
            for width, height, dpi in ((600, 800, 167), (1264, 1680, 300)):
                server.mode = 'selection_direct_overlay'
                server.calls, server.leaked, server.valid, server.review = [], False, True, None
                payload = dict(credentials=dict(vid='12345678', accessToken='synthetic-access',
                    refreshToken='synthetic-refresh', deviceId='eink334691225'+'0'*19),
                    web_cookies={'wr_vid':'12345678','wr_skey':'synthetic-web-access'},
                    book_id='42', uid='37', book_version=1, source_sha256=hashlib.sha256(BODY.encode()).hexdigest(),
                    mock_endpoint='http://127.0.0.1:'+str(server.server_port))
                child = subprocess.run([sys.executable, str(REPO/'scripts/run_native_direct_home_owner.py'),
                    '--koreader', str(args.koreader), '--candidate', str(candidate), '--width', str(width),
                    '--height', str(height), '--dpi', str(dpi)], input=json.dumps(payload).encode(),
                    capture_output=True, timeout=480)
                marker = b'\nWEREAD_DIRECT_HOME_OWNER_RUN='
                assert child.stdout.count(marker) == 1
                result = json.loads(child.stdout.split(marker, 1)[1].splitlines()[0])
                assert child.returncode == 0 and result['result'] == 'PASS', result
                assert all(result[key] is True for key in ('profile_removed','source_matches','home_record',
                    'offline_home_resume','page_restored','network_blocked','credential_file_audit','installed_bytes_match'))
                assert server.valid and not server.leaked
                assert all(path in ('/book/info','/book/chapterInfos','/book/chapterdownload') for _,_,path in server.calls)
        print('PASS: owner home runner against synthetic service at both screen sizes')
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == '__main__':
    main()
