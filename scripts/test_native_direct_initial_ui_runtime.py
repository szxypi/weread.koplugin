#!/usr/bin/env python3
"""Synthetic server and installed KOReader exercise for the one-shot UI broker."""
import hashlib
from http.server import ThreadingHTTPServer
from pathlib import Path
import subprocess
import tempfile
import threading
from urllib.parse import urlencode
from urllib.request import urlopen
import json

from native_direct_initial_ui_broker import execute
from native_direct_time_trial_store import Intent
from native_initial_position import no_chapter
from readtime_upload_model import guest_token
from shelf_flag_change_contract import state_hash
from test_native_direct_position_runtime import BODY,CLOUD_OFFSET,Handler
from test_secure_native_session import Backend
from verify_reader_progress import project

REPO=Path(__file__).resolve().parent.parent


def run(runtime):
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='weread-initial-ui-package-',dir='/dev/shm') as directory:
            candidate=Path(directory)/'candidate.zip'
            subprocess.run(['bash',str(REPO/'scripts/package_release.sh'),str(candidate)],cwd=REPO,check=True,capture_output=True)
            for width,height,dpi in ((600,800,167),(1264,1680,300)):
                for mode,armed in (('upload_initial_time',False),('upload_initial_time',True),('upload_initial_noack',True)):
                    server.mode=mode;server.calls=[];server.leaked=False;server.valid=True
                    server.cloud_offset=CLOUD_OFFSET;server.cloud_summary='Synthetic cloud point'
                    raw=BODY.encode();before=no_chapter(dict(bookId='42',chapterUid=0,chapterIdx=0,chapterOffset=0,progress=0,summary=''),'42')
                    shelf=state_hash(dict(books=[dict(bookId='42',finishReading=0,secret=0)],archive=[]))
                    expected=dict(book_id='42',uid='37',chapter_idx=1,native_before=before,
                        counts=dict(readingTime=2,recordReadingTime=0,ttsTime=0),version=1,native_shelf=shelf,
                        source_sha256=hashlib.sha256(raw).hexdigest())
                    creds=dict(vid='12345678',accessToken='synthetic-access',refreshToken='synthetic-refresh',deviceId='eink334691225'+'0'*19)
                    payload=dict(token='a'*32,armed=armed,expected=expected,credentials=creds,guest=guest_token({'feature':{}})[0],time_zone='+08:00',
                        book_id='42',uid='37',book_version=1,source_sha256=expected['source_sha256'],
                        web_cookies={'wr_vid':'12345678','wr_skey':'synthetic-web-access'},months=[1793462400],
                        mock_endpoint='http://127.0.0.1:'+str(server.server_port))
                    command=['python3',str(REPO/'scripts/run_native_direct_initial_ui.py'),'--koreader',str(runtime),
                        '--candidate',str(candidate),'--width',str(width),'--height',str(height),'--dpi',str(dpi)]
                    if armed:command.append('--armed')
                    intent=Intent(backend=Backend());report=dict(account_data_posts=0,dispatch_may_have_occurred=False)
                    def posts():return sum(path=='/book/read' for _,_,path in server.calls)
                    def read(path):
                        url=payload['mock_endpoint']+'/?'+urlencode({'url':path})
                        with urlopen(url,timeout=10) as response:return json.load(response)
                    def pair():
                        native=read('https://i.weread.qq.com/book/getProgress?bookId=42')
                        web=read('https://weread.qq.com/web/book/getProgress?bookId=42')
                        assert {key:native[key] for key in expected['counts']}==expected['counts']
                        assert state_hash(read('https://i.weread.qq.com/shelf/sync'))==shelf
                        return native,web
                    def before_check(metadata):
                        assert posts()==0 and metadata['before']==before
                        for _ in range(2):
                            native,web=pair()
                            assert no_chapter(native,'42')==before and no_chapter(web,'42')==before
                        return True
                    def after_check(metadata):
                        assert posts()==1 and server.cloud_offset==metadata['desired']['chapter_offset']
                        assert server.cloud_summary==metadata['desired']['summary']
                        for _ in range(2):
                            native,web=pair()
                            for raw_progress in (native,web):
                                observed=project(raw_progress,'42');observed['chapter_uid']=str(observed['chapter_uid'])
                                assert {key:observed[key] for key in metadata['desired']}==metadata['desired']
                        return True
                    try:
                        execute(payload,command,intent,raw,report,current=lambda:True,before=before_check,after=after_check)
                        assert mode!='upload_initial_noack'
                        assert report['result']==('INITIAL_NATIVE_UI_VERIFIED' if armed else 'INITIAL_NATIVE_UI_DRY_VERIFIED')
                        assert posts()==int(armed)
                    except ValueError as error:
                        if mode!='upload_initial_noack' or str(error)!='initial_ui/receipt':
                            print(report,server.calls,flush=True);raise
                        assert posts()==1 and intent.read()[0]['phase']=='claimed'
                    assert server.valid and not server.leaked
                    print(width,height,mode,'passed',flush=True)
    finally:
        server.shutdown();server.server_close()


if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser();parser.add_argument('--koreader',type=Path,required=True)
    run(parser.parse_args().koreader)
