#!/usr/bin/env python3
"""Production pin controls against a closed synthetic HTTP service."""
import argparse
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import sys
import threading
from urllib.parse import urlencode,urlsplit
from finish_change_contract import flags
from mock_weread import MockServer,BOOK_ID
from native_cloud_pin_trial import bind,check,validate_plan
from secure_native_cloud_pin_trial import NativeCloudPinTrialStore
from secure_shelf_experiment import canonical
from selection_trial_mock import Opener,credentials
from test_secure_native_session import Backend
from verify_eink_login import BASE,NativeProbe
from verify_native_finish_trial import TrialFailure,run
from verify_native_metadata import normalize_native

CASES=('normal','dry-run','lost-ack','empty-ack','no-pin','no-unpin','changed-flag','changed-group','position-change','host-loss')


class Server(MockServer):
    def __init__(self,case):
        super().__init__(0);self.finish_fixture=True;self.case=case;self.posts=[];self.pin=False
    def route(self,method,target,data):
        path=urlsplit(target).path
        if method=='POST' and path=='/shelf/top':
            if (len(self.posts)>=2 or set(data)!={'bookIds','albumIds','archiveIds','isDel'} or data['bookIds']!=[BOOK_ID]
                    or data['albumIds']!=[] or data['archiveIds']!=[] or data['isDel']!=len(self.posts)):
                raise ValueError('synthetic pin dispatch bound')
            self.posts.append(path)
            unchanged=self.case=='no-pin' and len(self.posts)==1 or self.case=='no-unpin' and len(self.posts)==2
            if not unchanged:self.pin=len(self.posts)==1
            if self.case=='position-change':self.control['progress_offset_delta']=1
            if self.case=='lost-ack':return 503,dict(errcode=-1)
            if self.case=='empty-ack':return 200,''
            return 200,dict(succ=1)
        result=super().route(method,target,data)
        if method=='GET' and path=='/shelf/sync':
            code,value=result;value=deepcopy(value)
            row=next((item for item in value['books'] if str(item['bookId'])==BOOK_ID),None)
            if row is not None:
                if self.pin:row['isTop']=1
                else:row.pop('isTop',None)
            if self.posts and self.case=='changed-flag':next(item for item in value['books'] if str(item['bookId'])!=BOOK_ID)['finishReading']=0
            if self.posts and self.case=='changed-group':value['archive'][0]['name']='Synthetic concurrent group edit'
            return code,value
        return result


class Probe(NativeProbe):
    def __init__(self,opener):super().__init__(opener);self.bound=None;self.payload=None;self.target=BOOK_ID
    def request(self,stage,url,body=None,credentials=None,timeout=15):
        allowed={BASE+'/shelf/sync'}|{BASE+'/book/'+route+'?'+urlencode({'bookId':self.target}) for route in ('getProgress','info')}
        if body is not None or url not in allowed:raise ValueError('native_cloud_pin/read_scope')
        return super().request(stage,url,credentials=credentials,timeout=timeout)
    def prepare(self,grant):
        shelf=self.request('shelf',BASE+'/shelf/sync',credentials=grant)
        progress=self.request('position',BASE+'/book/getProgress?'+urlencode({'bookId':self.target}),credentials=grant)
        self.bound=bind(grant['vid'],self.target,hashlib.sha256(canonical(grant)).hexdigest(),shelf,progress)
        metadata=normalize_native(self.request('metadata',BASE+'/book/info?'+urlencode({'bookId':self.target}),credentials=grant),self.target)
        self.payload=dict(credentials=grant,book_id=self.target,expected_metadata=metadata,shelf_books=len(flags(shelf)),
                          mark=deepcopy(self.bound['mark']),restore=deepcopy(self.bound['restore']))
        self.read(grant,False)
    def current(self,grant):
        validate_plan(self.bound)
        if hashlib.sha256(canonical(grant)).hexdigest()!=self.bound['grant_sha256']:raise ValueError('native_cloud_pin/grant')
    def read(self,grant,pinned):
        self.current(grant)
        shelf=self.request('shelf_check',BASE+'/shelf/sync',credentials=grant)
        progress=self.request('position_check',BASE+'/book/getProgress?'+urlencode({'bookId':self.target}),credentials=grant)
        return check(self.bound,shelf,progress,pinned)


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    parser.add_argument('--case',choices=CASES,default='normal');args=parser.parse_args()
    profiles=set(Path('/dev/shm').glob('weread-cloud-pin-trial-*'));server=Server(args.case)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    report=dict(result='UNVERIFIED',case=args.case,real_account_data_posts=0,authentication_posts=0)
    try:
        grant=credentials();probe=Probe(Opener(server));probe.prepare(grant)
        store=NativeCloudPinTrialStore(Backend());armed=args.case!='dry-run'
        command=[sys.executable,str(Path(__file__).with_name('run_owner_cloud_pin_trial.py')),'--koreader',str(args.koreader),'--candidate',str(args.candidate),
                 '--width',str(args.width),'--height',str(args.height),'--dpi',str(args.dpi),'--mock-port',str(server.server_port)]
        if armed:command.append('--armed')
        if args.case=='host-loss':
            original=probe.read
            def lost(credentials,pinned):
                if pinned:raise KeyboardInterrupt()
                return original(credentials,pinned)
            probe.read=lost
        try:
            result=run(probe,grant,store,command,armed=armed,mock_port=server.server_port)
            assert args.case in ('normal','dry-run');report['execution']=result;assert not store.pending()
        except TrialFailure as error:
            assert args.case not in ('normal','dry-run') and store.pending()
            report.update(expected_stop=True,native_ui=error.runner,independent_steps=error.steps)
            if error.runner is not None:assert error.runner['profile_removed']
            before=len(server.posts)
            try:run(probe,grant,store,command,armed=True,mock_port=server.server_port)
            except ValueError:pass
            else:raise AssertionError('pending native pin trial replayed')
            assert len(server.posts)==before;report['pending_replay_blocked']=True
        expected=0 if args.case=='dry-run' else 2 if args.case in ('normal','no-unpin') else 1
        assert len(server.posts)==expected
        report.update(result='PASS',mock_data_posts=expected,intent_state=store.read()[0]['phase'] if store.read()[0] else 'absent')
    finally:server.shutdown();server.server_close();thread.join()
    assert set(Path('/dev/shm').glob('weread-cloud-pin-trial-*'))==profiles
    print(json.dumps(report,ensure_ascii=False,indent=2));return 0


if __name__=='__main__':raise SystemExit(main())
