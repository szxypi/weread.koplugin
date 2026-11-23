#!/usr/bin/env python3
"""Run private native online-search acceptance against loopback services."""
import argparse
import hashlib
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading

import test_native_direct_position_runtime as fixture
from test_native_direct_online_search_ui_runtime import Handler

REPO=Path(__file__).resolve().parent.parent


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--koreader',type=Path,required=True);args=parser.parse_args()
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='weread-native-online-owner-test-',dir='/dev/shm') as directory:
            candidate=Path(directory)/'candidate.zip'
            subprocess.run(['bash',str(REPO/'scripts/package_release.sh'),str(candidate)],cwd=REPO,check=True,capture_output=True)
            for width,height,dpi in ((600,800,167),(1264,1680,300)):
                server.mode='match';server.calls=[];server.valid=True;server.leaked=False;server.uid='37'
                server.keyword='Unique paragraph 0100';begin=fixture.BODY.index(server.keyword)
                payload=dict(credentials=dict(vid='12345678',accessToken='synthetic-access',refreshToken='synthetic-refresh',
                    deviceId='eink334691225'+'0'*19),web_cookies={'wr_vid':'12345678','wr_skey':'synthetic-web-access'},
                    book_id='42',uid='37',book_version=1,source_sha256=hashlib.sha256(fixture.BODY.encode()).hexdigest(),
                    search_token=server.keyword,mock_endpoint='http://127.0.0.1:'+str(server.server_port),
                    neighbor=dict(uid='38',source_sha256=hashlib.sha256(fixture.BODY2.encode()).hexdigest(),
                                  search_token='Target paragraph 0100'),
                    online_search=dict(keyword=server.keyword,start=begin,finish=begin+len(server.keyword),
                                       allowed=[dict(chapter='37',start=0,finish=0)]))
                command=[sys.executable,str(REPO/'scripts/run_native_direct_owner.py'),'--koreader',str(args.koreader),
                    '--candidate',str(candidate),'--ui','--neighbor','--online-search','--width',str(width),
                    '--height',str(height),'--dpi',str(dpi)]
                child=subprocess.run(command,input=json.dumps(payload).encode(),capture_output=True,timeout=900)
                marker=b'\nWEREAD_DIRECT_OWNER_RUN=';assert child.stdout.count(marker)==1
                result=json.loads(child.stdout.split(marker,1)[1].splitlines()[0])
                assert child.returncode==0 and result['result']=='PASS',result
                assert all(result[key] is True for key in ('online_search','offline_network_guard','profile_removed',
                    'credential_file_audit','installed_bytes_match','neighbor_offline_roundtrip'))
                assert server.valid and not server.leaked
                assert not any(path in ('/book/read','/web/book/read','/book/addBookmark','/review/add') for _,_,path in server.calls)
        print('PASS: native online owner runner at both screen sizes using loopback services')
    finally:server.shutdown();server.server_close();thread.join()


if __name__=='__main__':main()
