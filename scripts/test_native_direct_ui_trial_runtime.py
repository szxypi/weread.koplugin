#!/usr/bin/env python3
"""Synthetic native ReaderUI trial, real worker, durable journal and duplex broker."""
import argparse
import hashlib
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
import secrets
import subprocess
import tempfile
import threading
from urllib.parse import urlencode
from urllib.request import urlopen

from native_chapter_remote_reference import search_token
from native_direct_ui_trial_broker import PROTOCOL,execute
from readtime_upload_model import guest_token
from secure_native_direct_ui_trial import NativeDirectUITrialStore
from shelf_flag_change_contract import state_hash
from test_native_direct_position_runtime import BODY,CLOUD_OFFSET,Handler,REPO
from test_secure_native_session import Backend
from txt_full_summary import digest


def run(runtime):
    server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='weread-direct-ui-trial-',dir='/dev/shm') as directory:
            candidate=Path(directory)/'candidate.zip'
            subprocess.run(['bash',str(REPO/'scripts/package_release.sh'),str(candidate)],cwd=REPO,check=True,capture_output=True)
            for width,height,dpi in ((600,800,167),(1264,1680,300)):
                for armed in (False,True):
                    server.mode='upload';server.calls=[];server.leaked=False;server.valid=True
                    server.cloud_offset=CLOUD_OFFSET;server.cloud_summary='Synthetic cloud point'
                    credentials=dict(vid='12345678',accessToken='synthetic-access',refreshToken='synthetic-refresh',
                        deviceId='eink334691225'+'0'*19)
                    before=dict(book_id='42',chapter_uid='37',chapter_idx=1,chapter_offset=CLOUD_OFFSET,
                        raw_percent=50,summary='Synthetic cloud point')
                    shelf={'books':[{'bookId':'42','finishReading':0,'secret':0}],'archive':[]}
                    source=BODY.encode();shelf_hash=state_hash(shelf)
                    plan=dict(protocol=PROTOCOL,owner_sha256=digest(credentials['vid']),source_sha256=hashlib.sha256(source).hexdigest(),
                        catalog_sha256='a'*64,grant_sha256=digest(credentials),shelf_sha256=shelf_hash,baseline=before,target=dict(before),
                        counts=dict(readingTime=100,recordReadingTime=0,ttsTime=0),version=1,chapter_progress=None)
                    payload=dict(credentials=credentials,book_id='42',uid='37',book_version=1,source_sha256=plan['source_sha256'],
                        search_token=search_token(source),web_cookies={'wr_vid':'12345678','wr_skey':'synthetic-web-access'},start_page=2,
                        mock_endpoint='http://127.0.0.1:'+str(server.server_port),trial=dict(plan=plan,armed=armed,
                        guest=guest_token({'feature':{}})[0],time_zone='+08:00',rpc_token=secrets.token_hex(16)))
                    store=NativeDirectUITrialStore(Backend());report={}
                    command=['python3',str(REPO/'scripts/run_native_direct_ui_trial.py'),'--koreader',str(runtime),
                        '--candidate',str(candidate),'--width',str(width),'--height',str(height),'--dpi',str(dpi)]
                    def observed(expected):
                        for base in ('https://i.weread.qq.com','https://weread.qq.com'):
                            path='/book/getProgress?bookId=42' if 'i.weread' in base else '/web/book/getProgress?bookId=42'
                            url=payload['mock_endpoint']+'/__proxy?'+urlencode({'url':base+path})
                            with urlopen(url,timeout=10) as response:data=json.load(response)
                            assert data['chapterOffset']==expected['chapter_offset'] and data['summary']==expected['summary']
                    def prior(seq,bound):observed(bound['baseline' if seq==1 else 'target'])
                    def after(seq,bound):observed(bound['target' if seq==1 else 'baseline'])
                    try:execute(payload,command,store,source,report,current=lambda:None,before=prior,after=after)
                    except Exception as error:
                        raise AssertionError(json.dumps(dict(report=report,calls=server.calls[-30:],summary=server.cloud_summary))) from error
                    assert report['result']==('NATIVE_DIRECT_UI_ROUNDTRIP_VERIFIED' if armed else 'NATIVE_DIRECT_UI_DISARMED_VERIFIED')
                    assert report['synthetic_posts']==(2 if armed else 0) and report['account_data_posts']==0
                    assert (store.read()[0] or {}).get('phase')==('retired' if armed else None)
                    assert server.cloud_offset==CLOUD_OFFSET and server.cloud_summary==before['summary']
                    assert server.valid and not server.leaked
                    assert sum(path=='/book/read' for _,_,path in server.calls)==(2 if armed else 0)
        print('PASS: native UI supervised dry run and two-step synthetic restore at both sizes')
    finally:
        server.shutdown();server.server_close();thread.join()


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True)
    args=parser.parse_args();run(args.koreader.resolve())
