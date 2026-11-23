#!/usr/bin/env python3
"""Validate the private cross-note owner runner with a loopback-only account."""
import argparse
from http.server import ThreadingHTTPServer
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading

from test_native_direct_position_runtime import BODY, BODY2, Handler, REPO


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--koreader',type=Path,required=True);args=parser.parse_args()
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='weread-cross-owner-test-',dir='/dev/shm') as directory:
            candidate=Path(directory)/'candidate.zip'
            subprocess.run(['bash',str(REPO/'scripts/package_release.sh'),str(candidate)],cwd=REPO,check=True,capture_output=True)
            for width,height,dpi in ((600,800,167),(1264,1680,300)):
                quote='Target paragraph 0100';first=BODY2.index(quote);marker=f'{first}-{first+len(quote)}'
                server.mode='selection_direct_overlay';server.calls=[];server.leaked=False;server.valid=True
                server.mark=dict(bookmarkId='synthetic-cross-mark',chapterUid=38,type=1,range=marker,
                    markText=quote,style=1,colorStyle=0,createTime=1700000000)
                server.review=dict(bookId='42',userVid=12345678,reviewId='synthetic-cross-thought',chapterUid=38,
                    type=1,range=marker,abstract=quote,content='Synthetic private thought',isPrivate=1)
                payload=dict(credentials=dict(vid='12345678',accessToken='synthetic-access',refreshToken='synthetic-refresh',deviceId='eink334691225'+'0'*19),
                    book_id='42',uid='38',origin_uid='37',book_version=1,cross_chapter=True,
                    source_sha256=hashlib.sha256(BODY2.encode()).hexdigest(),origin_source_sha256=hashlib.sha256(BODY.encode()).hexdigest(),
                    web_cookies={'wr_vid':'12345678','wr_skey':'synthetic-web-access'},mock_endpoint='http://127.0.0.1:'+str(server.server_port))
                for thoughts in (False,True):
                    payload.update(expect_thoughts=thoughts,expected_id='synthetic-cross-thought' if thoughts else 'synthetic-cross-mark')
                    server.calls=[]
                    child=subprocess.run([sys.executable,str(REPO/'scripts/run_native_direct_personal_owner.py'),'--koreader',str(args.koreader),
                        '--candidate',str(candidate),'--width',str(width),'--height',str(height),'--dpi',str(dpi)],
                        input=json.dumps(payload).encode(),capture_output=True,timeout=480)
                    frame=b'\nWEREAD_DIRECT_PERSONAL_OWNER_RUN='
                    assert child.stdout.count(frame)==1
                    result=json.loads(child.stdout.split(frame,1)[1].splitlines()[0])
                    assert child.returncode==0 and result.get('result')=='PASS',(result,server.calls)
                    expected=dict(id=payload['expected_id'],range=marker,text=quote)
                    if thoughts:expected['content_sha256']=hashlib.sha256(b'Synthetic private thought').hexdigest()
                    assert result['rows']==[expected] and result['navigation'] is True
                    assert all(result[key] is True for key in ('offline_reopen','credential_file_audit','installed_bytes_match','profile_removed'))
                    assert server.valid and not server.leaked and not any(path in ('/book/read','/book/addBookmark','/review/add') for _,_,path in server.calls)
        print('PASS: private cross-note runner, marks and thoughts, online/offline at both sizes')
    finally:server.shutdown();server.server_close();thread.join()


if __name__=='__main__':main()
