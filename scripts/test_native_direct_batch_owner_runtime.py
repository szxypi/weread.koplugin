#!/usr/bin/env python3
"""Verify the private owner runner against an isolated synthetic service."""
import hashlib
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading

import test_native_full_book_runtime as fixture

REPO = Path(__file__).resolve().parent.parent


def main():
    original = fixture.body
    fixture.body = lambda uid: '<html><body>' + ''.join(
        f'<p>Synthetic chapter {uid} paragraph {index} for offline reading.</p>' for index in range(20)) + '</body></html>'
    server = ThreadingHTTPServer(('127.0.0.1', 0), fixture.Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='weread-batch-owner-test-', dir='/dev/shm') as directory:
            server.resume, server.expired = False, False
            server.resume_marker = Path(directory)/'resume'
            server.chapters = []
            server.valid, server.leaked = True, False
            server.image_requests = server.tar_requests = 0
            sources = {uid: dict(sha256=hashlib.sha256(fixture.body(uid).encode()).hexdigest(), token='Synthetic')
                       for uid in ('37', '38', '39')}
            payload = dict(credentials=dict(vid='12345678', accessToken='synthetic-access',
                refreshToken='synthetic-refresh', deviceId='eink334691225'+'0'*19),
                web_cookies={'wr_vid':'12345678', 'wr_skey':'synthetic-web-access'},
                mock_endpoint='http://127.0.0.1:'+str(server.server_port), book_id='42', version=1, total=3, sources=sources)
            child = subprocess.run([sys.executable, str(REPO/'scripts/run_native_direct_batch_owner.py')],
                                   input=json.dumps(payload).encode(), capture_output=True, timeout=900)
            marker = b'\nWEREAD_BATCH_OWNER_RUN='
            assert child.stdout.count(marker) == 1
            report = json.loads(child.stdout.split(marker, 1)[1].splitlines()[0])
            assert child.returncode == 0 and report['result'] == 'PASS', report
            for key in ('profile_removed', 'source_matches', 'repeat_skipped', 'offline_render',
                        'network_blocked', 'credential_file_audit', 'installed_bytes_match'):
                assert report[key] is True
            assert report['screen_sizes'] == 2 and report['chapters'] == 3
            assert server.chapters == ['37', '38', '39']*2 and server.valid and not server.leaked
            shelf = [dict(bookId=str(1000+i), title=f'Synthetic shelf {i:03d}', author='Fixture') for i in range(28)]
            shelf.append(dict(bookId='42', title='Synthetic target', author='Fixture'))
            payload.update(full_shelf=True, shelf_books=shelf)
            child = subprocess.run([sys.executable, str(REPO/'scripts/run_native_direct_batch_owner.py')],
                                   input=json.dumps(payload).encode(), capture_output=True, timeout=900)
            assert child.stdout.count(marker) == 1
            report = json.loads(child.stdout.split(marker, 1)[1].splitlines()[0])
            assert child.returncode == 0 and report['result'] == 'PASS', report
            assert report['full_plugin'] and report['offline_reader'] and report['shelf_count']==len(shelf)
            assert report['downloaded_filter'] and report['detail_offline_status'] and report['home_native_only_safe']
            assert [row['reader_text_checked'] for row in report['samples']]==[1,1]
            assert server.chapters == ['37', '38', '39']*4 and server.valid and not server.leaked
        print('PASS: private owner batch runner against synthetic service at both sizes')
    finally:
        fixture.body = original
        server.shutdown();server.server_close();thread.join()


if __name__ == '__main__':
    main()
