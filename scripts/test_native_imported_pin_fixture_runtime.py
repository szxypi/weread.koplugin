#!/usr/bin/env python3
"""Exercise the packaged native imported-pin trial against synthetic HTTP only."""
import argparse
from copy import deepcopy
import json
from pathlib import Path
import sys
import threading
from urllib.parse import urlsplit

from mock_weread import MockServer
from native_direct_time_trial_store import Intent
from native_imported_pin_fixture_trial import run
from selection_trial_mock import credentials
from test_secure_native_session import Backend

TARGET='CB_SyntheticResume'
CASES=('normal','lost-first','changed-progress','lost-second','host-loss','dry-failure')


class Server(MockServer):
    def __init__(self,case):
        super().__init__(0);self.case=case;self.pin=False;self.posts=[];self.changed=False
    def route(self,method,target,data):
        path=urlsplit(target).path
        if method=='GET' and path=='/shelf/sync':
            book={'bookId':TARGET,'title':'Synthetic imported','author':'Synthetic','finishReading':0,'secret':0}
            if self.pin:book['isTop']=1
            return 200,{'books':[book,{'bookId':'900002','title':'Other','finishReading':0,'secret':0}],'archive':[]}
        if method=='GET' and path=='/book/info':return 200,{'bookId':TARGET,'title':'Synthetic imported','author':'Synthetic','version':1}
        if method=='GET' and path=='/book/getProgress':
            return 200,{'book':{'bookId':TARGET,'chapterUid':0,'chapterIdx':0,'chapterOffset':0,'progress':0,'updateTime':10},
                        'readingTime':1 if self.changed else 0}
        if method=='POST' and path=='/shelf/top':
            if (len(self.posts)>=2 or data!={'bookIds':[TARGET],'albumIds':[],'archiveIds':[],'isDel':len(self.posts)}):
                raise ValueError('synthetic/native_pin_scope')
            self.posts.append(path);self.pin=len(self.posts)==1
            if self.case=='changed-progress':self.changed=True
            if self.case=='lost-first' and len(self.posts)==1 or self.case=='lost-second' and len(self.posts)==2:
                return 503,{'errcode':-1}
            return 200,{'succ':1}
        raise ValueError('synthetic/native_pin_route')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    parser.add_argument('--case',choices=CASES,default='normal');args=parser.parse_args()
    before_profiles=set(Path('/dev/shm').glob('weread-cloud-pin-trial-*'));server=Server(args.case)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    report={'result':'UNVERIFIED','case':args.case,'real_account_writes':0,'authentication_posts':0}
    try:
        grant=credentials();records={name:Intent(backend=Backend()) for name in ('pin','restore')};armed=[]
        def observe(_identity):
            if args.case=='host-loss' and server.pin:raise ValueError('synthetic/host_loss')
            shelf=server.route('GET','https://i.weread.qq.com/shelf/sync',{})[1]
            progress=server.route('GET','https://i.weread.qq.com/book/getProgress?bookId='+TARGET,{})[1]
            return {'native':deepcopy(shelf),'web':deepcopy(shelf),'progress':deepcopy(progress)}
        before=observe(TARGET);metadata=server.route('GET','https://i.weread.qq.com/book/info?bookId='+TARGET,{})[1]
        command=[sys.executable,str(Path(__file__).with_name('run_owner_cloud_pin_trial.py')),'--koreader',str(args.koreader),
                 '--candidate',str(args.candidate if args.case!='dry-failure' else args.candidate.with_name('absent.zip')),
                 '--width',str(args.width),'--height',str(args.height),'--dpi',str(args.dpi),'--mock-port',str(server.server_port),'--imported']
        def once():return run(grant,TARGET,before,observe,lambda:True,records,metadata,command,lambda:armed.append(True),
                              mock_port=server.server_port,sleep=lambda _delay:None)
        outcome=once();expected=0 if args.case=='dry-failure' else 2 if args.case in ('normal','lost-second') else 1
        assert len(server.posts)==expected,(args.case,len(server.posts),outcome)
        assert (outcome['result']=='PASS')==(args.case=='normal')
        if args.case!='dry-failure':
            assert armed and records['pin'].read()[0] is not None
            assert once()['result']=='UNVERIFIED' and len(server.posts)==expected
        else:assert not armed and records['pin'].read()[0] is None
        report.update(result='PASS',mock_posts=len(server.posts),execution=outcome)
    finally:server.shutdown();server.server_close();thread.join()
    assert set(Path('/dev/shm').glob('weread-cloud-pin-trial-*'))==before_profiles
    print(json.dumps(report,ensure_ascii=False,indent=2));return 0


if __name__=='__main__':raise SystemExit(main())
