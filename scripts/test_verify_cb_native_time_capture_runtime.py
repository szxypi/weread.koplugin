#!/usr/bin/env python3
"""Exercise complete CB capture supervisor with an isolated synthetic server."""
import argparse,copy,os,threading
from contextlib import nullcontext
from pathlib import Path
from unittest.mock import patch
from urllib.parse import parse_qs,urlsplit

from mock_weread import CB_READING_ID
from native_time_capture_bundle import CaptureBundleStore
from test_cb_native_time_capture_runtime import VersionedServer
from test_secure_native_session import Backend
from test_uploaded_epub_native_reading_runtime import Opener
import verify_cb_native_time_capture as task

REPO=Path(__file__).resolve().parent.parent


class Server(VersionedServer):
    def route(self,method,target,data):
        url=urlsplit(target);query=parse_qs(url.query)
        if url.hostname=='i.weread.qq.com' and url.path=='/book/getProgress' and method=='GET':
            assert query=={'bookId':[CB_READING_ID]};value=self.get_progress(CB_READING_ID)
            value['book'].update(bookId=CB_READING_ID,readingTime=10,recordReadingTime=0,ttsTime=0)
            return 200,value
        if url.hostname=='i.weread.qq.com' and url.path=='/book/info' and method=='GET':
            assert query=={'bookId':[CB_READING_ID]};return 200,dict(bookId=CB_READING_ID,version=7)
        status,value=super().route(method,target,data)
        if url.path=='/web/book/getProgress' and status==200:
            value['book'].update(bookId=CB_READING_ID,readingTime=10,recordReadingTime=0,ttsTime=0)
        return status,value


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--candidate',type=Path,required=True)
    args=parser.parse_args();server=Server(0);server.cb_reading=True
    server.progress[CB_READING_ID]=dict(chapterUid=1,chapterIdx=1,chapterOffset=0,progress=1,summary='Synthetic full summary')
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    saved=dict(vid='900000',cookies=dict(wr_vid='900000',wr_skey='mock_key'))
    grant=dict(vid='900000',deviceId='eink334691225'+'1'*19,accessToken='synthetic-access',refreshToken='synthetic-refresh')
    class Session:
        def load(self):return copy.deepcopy(saved)
    class NativeStore:
        def load(self,owner):assert owner=='900000';return copy.deepcopy(grant)
    class LoopWeb(task.CaptureWeb):
        def __init__(self):super().__init__();self.opener=Opener(server)
    class LoopNative(task.Native):
        def __init__(self,credentials,book):super().__init__(credentials,book,opener=Opener(server))
    original_execute=task.execute
    def execute(payload,command):
        payload=dict(payload,cb_mock_port=server.server_port)
        return original_execute(payload,command)
    pieces={};backend=Backend();chunks=lambda index:pieces.setdefault(index,Backend())
    bundle=CaptureBundleStore(backend,chunks=chunks,lock=nullcontext,imported=True)
    command=['python3',str(REPO/'scripts/run_native_time_capture.py'),'--koreader',str(args.koreader),
             '--candidate',str(args.candidate),'--cb-reading','--cb-mock-port',str(server.server_port),'--sqlite-evidence']
    try:
        os.environ.pop('LD_LIBRARY_PATH',None)
        with patch.object(task,'CaptureWeb',LoopWeb),patch.object(task,'Native',LoopNative),patch.object(task,'execute',execute),\
             patch.object(task,'save_refreshed_web_session',return_value=False):
            report=task.run(Session(),NativeStore(),bundle,command,1)
        if report.get('result')!='CB_NATIVE_WINDOW_CAPTURED':raise ValueError('synthetic_supervisor '+repr(report))
        assert bundle.read()[0]['plan']['book_id']==CB_READING_ID and report['account_data_posts']==0
        assert server.request_totals[('/web/book/read','')]==0 and server.request_totals[('/web/login/renewal','')]==0
        print('PASS: complete isolated CB native capture and immutable readback',flush=True)
    finally:server.shutdown();thread.join();server.server_close()


if __name__=='__main__':main()
