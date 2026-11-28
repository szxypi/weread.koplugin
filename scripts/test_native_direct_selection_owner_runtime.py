#!/usr/bin/env python3
"""Private owner-selection runner against a closed synthetic service."""
import argparse
import hashlib
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import tempfile
import threading

from test_native_direct_position_runtime import BODY,Handler,REPO
from verify_native_direct_position_owner import independent_selection


def run(runtime):
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='weread-selection-owner-test-',dir='/dev/shm') as directory:
            candidate=Path(directory)/'candidate.zip'
            subprocess.run(['bash',str(REPO/'scripts/package_release.sh'),str(candidate)],cwd=REPO,check=True,capture_output=True)
            for width,height,dpi in ((600,800,167),(1264,1680,300)):
                server.mode='selection_direct_owner';server.calls=[];server.leaked=False;server.valid=True;server.mark=None;server.review=None
                credentials=dict(vid='12345678',accessToken='synthetic-access',refreshToken='synthetic-refresh',deviceId='eink334691225'+'0'*19)
                payload=dict(credentials=credentials,book_id='42',uid='37',book_version=1,
                    source_sha256=hashlib.sha256(BODY.encode()).hexdigest(),search_token='Unique paragraph 0001',
                    web_cookies={'wr_vid':'12345678','wr_skey':'synthetic-web-access'},selection=True,annotation_preview=True,offline_draft=True,
                    mock_endpoint='http://127.0.0.1:'+str(server.server_port))
                child=subprocess.run(['python3',str(REPO/'scripts/run_native_direct_position_owner.py'),'--koreader',str(runtime),
                    '--candidate',str(candidate),'--width',str(width),'--height',str(height),'--dpi',str(dpi)],
                    input=json.dumps(payload).encode(),capture_output=True,timeout=300)
                marker=b'\nWEREAD_DIRECT_POSITION_OWNER_RUN='
                assert child.stdout.count(marker)==1
                result=json.loads(child.stdout.split(marker,1)[1].splitlines()[0])
                assert child.returncode==0 and result.get('result')=='PASS', result
                assert result['credential_file_audit'] and result['installed_bytes_match'] and result['profile_removed']
                assert independent_selection(BODY.encode(),{key:result['position'][key] for key in ('ok','selection','range','quote')})
                assert result['position']['mark_preview'] and result['position']['thought_preview']
                assert result['position']['offline_draft']
                assert result['position']['selection']=='Unique paragraph 0001'
                assert server.valid and not server.leaked
                assert not any(path in ('/book/read','/web/book/read','/book/addBookmark','/review/add') for _,_,path in server.calls)
        print('PASS: private native selection owner probe at both sizes without account writes')
    finally:
        server.shutdown();server.server_close();thread.join()


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True)
    args=parser.parse_args();run(args.koreader.resolve())
