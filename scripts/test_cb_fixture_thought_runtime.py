#!/usr/bin/env python3
"""Exercise fixture-only thought transport against a closed loopback server."""
import argparse
import hashlib
import json
import threading
from urllib.parse import urlencode,urlsplit
from urllib.request import ProxyHandler,Request,build_opener

from cb_fixture_highlight_trial import Intent as SeedIntent,prepare
from cb_fixture_thought_trial import ThoughtIntent,execute
from mock_weread import CB_READING_ID,CHAPTERS,MockServer
from selection_trial_mock import credentials
from test_secure_native_session import Backend
from verify_cb_fixture_thought_trial import ScopedThoughtNative
from verify_eink_login import NoRedirect


class Server(MockServer):
    def __init__(self,case):
        super().__init__(0);self.case=case;self.cb_reading=True;self.selection_fixture=True;self.combined_upload_read=True
        self.selection_marks={};self.selection_thoughts={};self.sent=[]
        self.progress[CB_READING_ID]=dict(chapterUid=2,chapterIdx=2,chapterOffset=0,progress=0,summary='')
    def route(self,method,target,data):
        parsed=urlsplit(target)
        if parsed.hostname=='i.weread.qq.com' and method=='GET' and parsed.path=='/book/getProgress':
            from urllib.parse import parse_qs
            if parse_qs(parsed.query)!={'bookId':[CB_READING_ID]}:raise ValueError('synthetic scope')
            return 200,self.get_progress(CB_READING_ID)
        if parsed.hostname=='i.weread.qq.com' and method=='POST':
            names={'/book/addBookmark':'seed_create','/review/add':'thought_create',
                   '/review/useredit':'thought_edit','/review/delete':'thought_delete','/book/removeBookmark':'seed_delete'}
            stage=names.get(parsed.path)
            if stage:
                self.sent.append(stage);self.control['selection_thought_mode']='no_change' if self.case==stage else 'plain'
                if self.case==stage and stage in ('thought_edit','thought_delete'):
                    assert data.get('reviewId') in self.selection_thoughts
                    self.selection_posts+=1;return 200,dict(succ=1)
        return super().route(method,target,data)


class Opener:
    def __init__(self,server):self.server=server;self.opener=build_opener(ProxyHandler({}),NoRedirect())
    def open(self,request,timeout):
        parsed=urlsplit(request.full_url)
        if (parsed.hostname!='i.weread.qq.com' or request.get_header('Vid')!='900000'
                or request.get_header('Accesstoken')!='mock-native-access' or request.get_method() not in ('GET','POST')):
            raise ValueError('synthetic transport')
        if request.get_method()=='POST' and parsed.path not in {'/book/addBookmark','/book/removeBookmark','/review/add','/review/useredit','/review/delete'}:
            raise ValueError('synthetic transport')
        url='http://127.0.0.1:'+str(self.server.server_port)+'/__proxy?'+urlencode(dict(url=request.full_url))
        return self.opener.open(Request(url,data=request.data,headers=dict(request.header_items()),method=request.get_method()),timeout=timeout)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case',choices=('normal','seed_create','thought_create','thought_edit','thought_delete','seed_delete'),default='normal')
    args=parser.parse_args();server=Server(args.case);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        grant=credentials();seed=SeedIntent(Backend());thought=ThoughtIntent(Backend())
        native=ScopedThoughtNative(CB_READING_ID,grant,lambda:True,seed,thought,opener=Opener(server))
        baseline=native.observe(grant);raw=server.chapter_source(2)
        sample=dict(book_id=CB_READING_ID,chapter_uid='2',chapters=CHAPTERS,source_format='web_xhtml',source=raw,
                    source_raw_sha256=hashlib.sha256(raw.encode()).hexdigest())
        _plan,native.body=prepare('900000',CB_READING_ID,'a'*32,sample,700,baseline)
        def run():return execute('900000',CB_READING_ID,'a'*32,sample,700,baseline,seed,thought,lambda:True,
            lambda:native.observe(grant),lambda phase,value,receipt:native.send(phase,value,receipt,grant),
            lambda phase,value,receipt:native.send_thought(phase,value,receipt,grant),nonce='b'*32,sleep=lambda _n:None)
        if args.case=='normal':
            result=run();assert result['result']=='PASS' and not server.selection_marks and not server.selection_thoughts
            assert seed.read()==thought.read()==(None,None)
        else:
            try:run()
            except ValueError:pass
            else:raise AssertionError('unconfirmed change accepted')
            before=list(server.sent)
            try:run()
            except ValueError:pass
            else:raise AssertionError('pending write replayed')
            assert server.sent==before and (seed.read()[0] or thought.read()[0])
        print(json.dumps(dict(result='PASS',case=args.case,mock_posts=len(server.sent),no_replay=True)))
    finally:server.shutdown();thread.join();server.server_close()


if __name__=='__main__':main()
