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

from bookmark_point import project
from test_native_direct_position_runtime import BODY, BODY2, CROSS_OFFSET, Handler, REPO


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
                point=project(BODY2,CROSS_OFFSET)
                original_mark=server.mark
                for variant in ('marks','thoughts','bookmarks'):
                    thoughts,bookmarks=variant=='thoughts',variant=='bookmarks'
                    server.mark=(dict(bookmarkId='synthetic-cross-bookmark',chapterUid=38,type=0,range=point['range'],
                        markText=point['markText'],style=0,createTime=1700000000) if bookmarks else original_mark)
                    payload.update(expect_thoughts=thoughts,expect_bookmarks=bookmarks,
                        expected_id='synthetic-cross-thought' if thoughts else 'synthetic-cross-bookmark' if bookmarks else 'synthetic-cross-mark')
                    if bookmarks:payload['expected_preview']=point['markText']
                    else:payload.pop('expected_preview',None)
                    server.calls=[]
                    child=subprocess.run([sys.executable,str(REPO/'scripts/run_native_direct_personal_owner.py'),'--koreader',str(args.koreader),
                        '--candidate',str(candidate),'--width',str(width),'--height',str(height),'--dpi',str(dpi)],
                        input=json.dumps(payload).encode(),capture_output=True,timeout=480)
                    frame=b'\nWEREAD_DIRECT_PERSONAL_OWNER_RUN='
                    assert child.stdout.count(frame)==1
                    result=json.loads(child.stdout.split(frame,1)[1].splitlines()[0])
                    assert child.returncode==0 and result.get('result')=='PASS',(result,server.calls)
                    expected=dict(id=payload['expected_id'],range=point['range'] if bookmarks else marker,
                        text=point['markText'] if bookmarks else quote)
                    if thoughts:expected['content_sha256']=hashlib.sha256(b'Synthetic private thought').hexdigest()
                    assert result['rows']==[expected] and result['navigation'] is True
                    assert all(result[key] is True for key in ('offline_reopen','credential_file_audit','installed_bytes_match','profile_removed'))
                    assert server.valid and not server.leaked and not any(path in ('/book/read','/book/addBookmark','/review/add') for _,_,path in server.calls)
        print('PASS: private cross-note runner, marks, thoughts and bookmarks, online/offline at both sizes')
    finally:server.shutdown();server.server_close();thread.join()


if __name__=='__main__':main()
