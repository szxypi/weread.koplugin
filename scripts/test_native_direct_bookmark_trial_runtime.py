#!/usr/bin/env python3
"""Supervised direct bookmark UI against a closed synthetic service."""
import argparse
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
from urllib.parse import parse_qs,urlsplit

from annotation_experiment_model import digest
from bookmark_point import first_position
from bookmark_trial_model import request
from native_direct_highlight_trial_broker import execute
from secure_bookmark_trial import BookmarkTrialStore
from test_native_direct_position_runtime import BODY,Handler,REPO
from test_native_direct_selection_trial_runtime import Probe as SourceProbe
from test_secure_native_session import Backend


class TrialHandler(Handler):
    def dispatch(self):
        server=self.server;target=urlsplit(parse_qs(urlsplit(self.path).query).get('url',[''])[0])
        if self.command=='POST' and target.hostname=='i.weread.qq.com' and target.path in ('/book/addBookmark','/book/removeBookmark'):
            server.calls.append((self.command,target.hostname,target.path))
            body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            if target.path=='/book/addBookmark':
                assert server.mark is None and body==server.expected
                server.mark=dict(bookmarkId='synthetic-direct-mark',chapterUid=37,type=0,range=body['range'],markText=body['markText'],
                    style=body['style'],createTime=1700000000)
                if server.case=='no_effect':server.mark=None
            else:
                assert server.mark and body=={'bookmarkIds':['synthetic-direct-mark']}
                server.mark=None
            data=json.dumps({} if server.case=='lost_ack' else {'succ':1}).encode();self.send_response(200)
            self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data);return
        return super().dispatch()


class Web:
    def verify_account(self):pass
    def request(self,*_args):return dict(bookId='42',chapterUid=37,chapterOffset=10,progress=50)


class Probe:
    def __init__(self,server):
        self.source=SourceProbe(server);self.source.web=Web()
        def baseline(_credentials,_stage):
            assert server.mark is None and server.review is None
            return self.source.plan.baseline
        self.source.baseline=baseline
        self.source.plan.web_position=dict(chapter='37',offset=10,percent=50)
        context=self.source.payload['selection_preview']['body']
        self.body=request(context,BODY,first_position(BODY));self.target=None;self.server=server;server.expected=self.body
    def current(self):self.source.current()
    def read(self,_credentials,*,deleted=False):
        row=self.server.mark
        if deleted:assert row is None
        else:
            assert row and all(row[k]==self.body[k] for k in ('chapterUid','type','style','range','markText'))
        return (dict(id=row['bookmarkId'],sha256=digest(row)) if row else None),self.source.plan.baseline


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--koreader',type=Path,required=True);args=parser.parse_args()
    server=ThreadingHTTPServer(('127.0.0.1',0),TrialHandler);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='weread-direct-bookmark-test-',dir='/dev/shm') as directory:
            candidate=Path(directory)/'candidate.zip'
            subprocess.run(['bash',str(REPO/'scripts/package_release.sh'),str(candidate)],cwd=REPO,check=True,capture_output=True)
            for width,height,dpi in ((600,800,167),(1264,1680,300)):
                for armed,case in ((False,'normal'),(True,'normal'),(True,'lost_ack'),(True,'no_effect')):
                    server.case=case;server.mode='selection_direct_trial';server.calls=[];server.leaked=False;server.valid=True;server.mark=None;server.review=None
                    probe=Probe(server);store=BookmarkTrialStore(Backend(),native=True);report={}
                    source=dict(book_id='42',uid='37',book_version=1,source_sha256=probe.source.payload['source_raw_sha256'],
                        mock_endpoint='http://127.0.0.1:'+str(server.server_port))
                    command=[sys.executable,str(REPO/'scripts/run_native_direct_selection_trial.py'),'--bookmark','--koreader',str(args.koreader),
                        '--candidate',str(candidate),'--width',str(width),'--height',str(height),'--dpi',str(dpi)]
                    credentials=probe.source.payload['selection_preview']['credentials']
                    try:execute(probe,credentials,store,command,source=source,armed=armed,report=report,bookmark=True)
                    except Exception as error:
                        if case!='no_effect':raise AssertionError((width,armed,case,report,repr(error))) from error
                        assert report['result']=='UNVERIFIED' and store.read()[0]['phase']=='create_pending'
                        count=len(server.calls)
                        try:execute(probe,credentials,store,command,source=source,armed=True,report={},bookmark=True)
                        except ValueError:pass
                        else:raise AssertionError('pending bookmark replayed')
                        assert len(server.calls)==count
                    else:assert case!='no_effect'
                    posts=[path for method,host,path in server.calls if method=='POST' and host=='i.weread.qq.com' and path.startswith('/book/') and path in ('/book/addBookmark','/book/removeBookmark')]
                    assert posts==(['/book/addBookmark'] if case=='no_effect' else ['/book/addBookmark','/book/removeBookmark'] if armed else [])
                    assert server.valid and not server.leaked and server.mark is None
                    assert (store.read()[0] is None)==(case!='no_effect')
        print('PASS: two sizes; dry run, bookmark lifecycle, lost acknowledgements and replay blocking')
    finally:server.shutdown();server.server_close();thread.join()


if __name__=='__main__':main()
