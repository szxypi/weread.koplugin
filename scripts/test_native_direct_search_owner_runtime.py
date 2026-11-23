#!/usr/bin/env python3
"""Exercise the private offline-search owner runner using a loopback service."""
import argparse
import hashlib
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading

import test_native_full_book_runtime as fixture

REPO=Path(__file__).resolve().parent.parent
fixture.body=lambda uid: '<html><body>'+''.join(
    f'<p>Chapter {uid} synthetic paragraph {index:04d}, unique reading text to verify offline results.</p>'
    for index in range(1,101))+'</body></html>'


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--koreader',type=Path,required=True);args=parser.parse_args()
    server=ThreadingHTTPServer(('127.0.0.1',0),fixture.Handler)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='weread-native-search-owner-test-',dir='/dev/shm') as directory:
            candidate=Path(directory)/'candidate.zip'
            subprocess.run(['bash',str(REPO/'scripts/package_release.sh'),str(candidate)],cwd=REPO,check=True,capture_output=True)
            for width,height,dpi in ((600,800,167),(1264,1680,300)):
                server.resume=server.expired=False;server.chapters=[];server.valid=True;server.leaked=False
                server.image_requests=server.tar_requests=0
                payload=dict(credentials=dict(vid='12345678',accessToken='synthetic-access',
                    refreshToken='synthetic-refresh',deviceId='eink334691225'+'0'*19),book_id='42',uid='37',book_version=1,
                    source_sha256=hashlib.sha256(fixture.body('37').encode()).hexdigest(),
                    search_token='Chapter 37 synthetic paragraph 0050',mock_endpoint='http://127.0.0.1:'+str(server.server_port),
                    neighbor=dict(uid='38',source_sha256=hashlib.sha256(fixture.body('38').encode()).hexdigest(),
                                  search_token='Chapter 38 synthetic paragraph 0050'))
                command=[sys.executable,str(REPO/'scripts/run_native_direct_owner.py'),'--koreader',str(args.koreader),
                    '--candidate',str(candidate),'--ui','--neighbor','--offline-search','--width',str(width),
                    '--height',str(height),'--dpi',str(dpi)]
                child=subprocess.run(command,input=json.dumps(payload).encode(),capture_output=True,timeout=600)
                marker=b'\nWEREAD_DIRECT_OWNER_RUN='
                assert child.stdout.count(marker)==1
                result=json.loads(child.stdout.split(marker,1)[1].splitlines()[0])
                assert child.returncode==0 and result['result']=='PASS',result
                assert all(result[key] is True for key in ('offline_search','offline_network_guard','profile_removed',
                    'credential_file_audit','installed_bytes_match','neighbor_offline_roundtrip'))
                assert server.valid and not server.leaked and server.chapters==['37','38']
        print('PASS: installed offline search owner runner at both screen sizes')
    finally:
        server.shutdown();server.server_close();thread.join()


if __name__=='__main__':main()
