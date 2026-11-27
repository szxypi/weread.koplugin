#!/usr/bin/env python3
"""Exercise the supervised selection lifecycle against a closed synthetic server."""
import argparse
from http.server import ThreadingHTTPServer
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
from types import SimpleNamespace
from urllib.parse import parse_qs,urlsplit

from annotation_experiment_model import note_text
from highlight_trial_model import txt_request
from native_direct_selection_trial_broker import execute
from owner_selection_preview import choose
from secure_selection_trial import SelectionTrialStore
from selection_trial_model import bind,bind_txt
from test_native_direct_position_runtime import BODY,Handler,REPO,TXT
from test_secure_native_session import Backend


class TrialHandler(Handler):
    def dispatch(self):
        server=self.server;target=urlsplit(parse_qs(urlsplit(self.path).query).get('url',[''])[0])
        if self.command=='POST' and target.hostname=='i.weread.qq.com' and target.path in ('/review/add','/review/useredit','/review/delete'):
            server.calls.append((self.command,target.hostname,target.path))
            body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            if target.path=='/review/add':
                assert server.review is None and body==server.expected
                server.review=dict(reviewId='synthetic-direct-thought',bookId='42',userVid='12345678',chapterUid=37,type=1,
                    range=body['range'],abstract=body['abstract'],content=body['content'],isPrivate=1,createTime=1700000000)
            elif target.path=='/review/useredit':
                assert server.review and body=={'reviewId':'synthetic-direct-thought','content':server.edited}
                server.review['content']=body['content']
            else:
                assert server.review and body=={'reviewId':'synthetic-direct-thought'}
                server.review=None
            if server.case=='no_effect' and target.path=='/review/add':server.review=None
            data=json.dumps({} if server.case=='lost_ack' else {'succ':1}).encode();self.send_response(200);self.send_header('Content-Length',str(len(data)))
            self.end_headers();self.wfile.write(data);return
        return super().dispatch()


class Probe:
    def __init__(self,server,*,txt=False):
        chosen=choose(BODY,{},'42','37',1);row=chosen['reference'];nonce='1'*32
        context=dict(bookId='42',chapterUid='37',bookVersion=1,type=1,range=row['range'],abstract=row['markText'],isPrivate=1)
        credentials=dict(vid='12345678',accessToken='synthetic-access',refreshToken='synthetic-refresh',deviceId='eink334691225'+'0'*19)
        cookies={'wr_vid':'12345678','wr_skey':'synthetic-web-access'}
        self.payload=dict(book_id='42',chapter_uid='37',source_raw_sha256=hashlib.sha256(BODY.encode()).hexdigest(),cookies=cookies,
            selection_preview=dict(credentials=credentials,first=chosen['first'],last=chosen['last'],reference=row,body=dict(context,content=note_text(nonce))))
        baseline=dict(thoughts={},marks={'updated':{},'chapters':{}},position={},shelf={})
        if txt:
            mark=txt_request('42','37',TXT,baseline)
            context.update(bookVersion=0,range=mark['range'],abstract=mark['markText'])
            sha=hashlib.sha256(TXT.encode()).hexdigest()
            self.payload.update(source_raw_sha256=sha,
                selection_preview=dict(credentials=credentials,body=dict(context,content=note_text(nonce))))
            chapter=dict(owner='12345678',book_id='42',chapter_uid='37',chapter_idx=1,source_sha256=sha,
                grant_sha256='a'*64,catalog_sha256='b'*64)
            bound=bind_txt(chapter,context,baseline,{},nonce,len(TXT.encode()))
        else:bound=bind('12345678',self.payload,context,baseline,[{'chapterUid':37}],{},nonce)
        self.plan=SimpleNamespace(bound=bound,baseline=baseline);self.server=server;self.cleanup_posts=0;self.derived_chapter_metadata_changed=False
        server.expected=self.payload['selection_preview']['body'];server.edited=note_text(nonce,True)
    def current(self):pass
    def baseline(self,_credentials,_stage):assert self.server.review is None
    def read_step(self,_credentials,step,target):
        assert target=='synthetic-direct-thought'
        if step==3:assert self.server.review is None
        else:
            row=self.server.review;assert row and row['reviewId']==target and row['isPrivate']==1
            assert row['content']==(self.server.expected['content'] if step==1 else self.server.edited)
            assert row['range']==self.server.expected['range'] and row['abstract']==self.server.expected['abstract']
        return None
    def cleanup(self,_credentials,store,receipt):return store.verified_cleanup(receipt)
    def final(self,_credentials,_cookies):assert self.server.review is None


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--koreader',type=Path,required=True)
    parser.add_argument('--offline-draft',action='store_true');parser.add_argument('--txt',action='store_true');args=parser.parse_args()
    server=ThreadingHTTPServer(('127.0.0.1',0),TrialHandler);server.plain_text=args.txt
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='weread-direct-trial-test-',dir='/dev/shm') as directory:
            candidate=Path(directory)/'candidate.zip'
            subprocess.run(['bash',str(REPO/'scripts/package_release.sh'),str(candidate)],cwd=REPO,check=True,capture_output=True)
            for width,height,dpi in ((600,800,167),(1264,1680,300)):
                cases=((False,'normal'),(True,'normal')) if args.offline_draft else ((False,'normal'),(True,'normal'),(True,'lost_ack'),(True,'no_effect'))
                for armed,case in cases:
                    server.case=case;server.mode='selection_direct_trial';server.calls=[];server.leaked=False;server.valid=True;server.mark=None;server.review=None
                    probe=Probe(server,txt=args.txt);store=SelectionTrialStore(Backend());receipt=store.prepare(probe.plan.bound);report={}
                    source=dict(book_id='42',uid='37',book_version=0 if args.txt else 1,source_sha256=probe.payload['source_raw_sha256'],
                        mock_endpoint='http://127.0.0.1:'+str(server.server_port))
                    if args.txt:source.update(plain_text=True,chapter_idx=1,source_bytes=len(TXT.encode()))
                    command=[sys.executable,str(REPO/'scripts/run_native_direct_selection_trial.py'),'--koreader',str(args.koreader),
                        '--candidate',str(candidate),'--width',str(width),'--height',str(height),'--dpi',str(dpi)]
                    try:execute(probe,probe.payload['selection_preview']['credentials'],store,receipt,command,source=source,armed=armed,report=report,offline_draft=args.offline_draft)
                    except Exception as error:
                        if case!='no_effect':raise AssertionError((width,armed,case,report,repr(error))) from error
                        assert report['result']=='UNVERIFIED' and store.read()[0]['phase']=='pending'
                        count=len(server.calls)
                        try:execute(probe,probe.payload['selection_preview']['credentials'],store,store.read()[1],command,source=source,armed=True,report={})
                        except ValueError:pass
                        else:raise AssertionError('pending trial replayed')
                        assert len(server.calls)==count
                    else:assert case!='no_effect'
                    if args.offline_draft:assert report['offline_draft_prepared'] and report['offline_draft_submitted']==armed
                    posts=[path for method,host,path in server.calls if method=='POST' and host=='i.weread.qq.com' and path.startswith('/review/')]
                    assert posts==(['/review/add'] if case=='no_effect' else ['/review/add','/review/useredit','/review/delete'] if armed else [])
                    assert server.valid and not server.leaked and server.review is None
                    assert (store.read()[0] is None)==(armed and case!='no_effect')
        print('PASS: two dimensions; offline draft dry run and round trip' if args.offline_draft else
            'PASS: two dimensions; dry run, round trip, lost acknowledgements, and no-effect replay blocking')
    finally:server.shutdown();server.server_close();thread.join()


if __name__=='__main__':main()
