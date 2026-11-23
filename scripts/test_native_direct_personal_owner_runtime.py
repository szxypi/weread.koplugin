#!/usr/bin/env python3
"""Owner-probe boundary with synthetic-only credentials and a loopback service."""
import argparse
from http.server import ThreadingHTTPServer
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading

from test_native_direct_position_runtime import BODY,Handler,REPO


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--koreader',type=Path,required=True);args=parser.parse_args()
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='weread-direct-personal-owner-test-',dir='/dev/shm') as directory:
            candidate=Path(directory)/'candidate.zip'
            subprocess.run(['bash',str(REPO/'scripts/package_release.sh'),str(candidate)],cwd=REPO,check=True,capture_output=True)
            for width,height,dpi in ((600,800,167),(1264,1680,300)):
                quote='Unique paragraph 0001';first=BODY.index(quote)
                server.mode='selection_direct_overlay';server.calls=[];server.leaked=False;server.valid=True;server.review=None
                server.mark=dict(bookmarkId='synthetic-direct-mark',chapterUid=37,type=1,range=f'{first}-{first+len(quote)}',
                    markText=quote,style=1,colorStyle=0,createTime=1700000000)
                payload=dict(credentials=dict(vid='12345678',accessToken='synthetic-access',refreshToken='synthetic-refresh',deviceId='eink334691225'+'0'*19),
                    book_id='42',uid='37',book_version=1,source_sha256=hashlib.sha256(BODY.encode()).hexdigest(),
                    web_cookies={'wr_vid':'12345678','wr_skey':'synthetic-web-access'},mock_endpoint='http://127.0.0.1:'+str(server.server_port))
                child=subprocess.run([sys.executable,str(REPO/'scripts/run_native_direct_personal_owner.py'),'--koreader',str(args.koreader),
                    '--candidate',str(candidate),'--width',str(width),'--height',str(height),'--dpi',str(dpi)],input=json.dumps(payload).encode(),
                    capture_output=True,timeout=420)
                marker=b'\nWEREAD_DIRECT_PERSONAL_OWNER_RUN='
                assert child.stdout.count(marker)==1
                result=json.loads(child.stdout.split(marker,1)[1].splitlines()[0])
                assert child.returncode==0 and result.get('result')=='PASS',(result,server.calls)
                assert result['rows']==[dict(id='synthetic-direct-mark',range=f'{first}-{first+len(quote)}',text=quote)]
                assert result['offline_reopen'] and result['credential_file_audit'] and result['installed_bytes_match'] and result['profile_removed']
                assert server.valid and not server.leaked
                assert not any(path in ('/book/read','/book/addBookmark','/review/add') for _,_,path in server.calls)
                server.review=dict(bookId='42',userVid=12345678,reviewId='synthetic-direct-thought',chapterUid=37,
                    type=1,range=f'{first}-{first+len(quote)}',abstract=quote,content='Synthetic private thought',isPrivate=1)
                payload['expect_thoughts']=True;server.calls=[]
                child=subprocess.run([sys.executable,str(REPO/'scripts/run_native_direct_personal_owner.py'),'--koreader',str(args.koreader),
                    '--candidate',str(candidate),'--width',str(width),'--height',str(height),'--dpi',str(dpi)],input=json.dumps(payload).encode(),
                    capture_output=True,timeout=420)
                assert child.stdout.count(marker)==1
                result=json.loads(child.stdout.split(marker,1)[1].splitlines()[0])
                assert child.returncode==0 and result.get('result')=='PASS',(result,server.calls)
                assert result['rows']==[dict(id='synthetic-direct-thought',range=f'{first}-{first+len(quote)}',text=quote,
                    content_sha256=hashlib.sha256(b'Synthetic private thought').hexdigest())]
                assert result['offline_reopen'] and result['credential_file_audit'] and result['installed_bytes_match'] and result['profile_removed']
                assert server.valid and not server.leaked and any(path=='/review/list' for _,_,path in server.calls)
                assert not any(path in ('/book/read','/book/addBookmark','/review/add') for _,_,path in server.calls)
        print('PASS: private owner runner, online/offline personal mark and credential audit at both sizes')
    finally:server.shutdown();server.server_close();thread.join()


if __name__=='__main__':main()
