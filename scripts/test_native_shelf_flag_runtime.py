#!/usr/bin/env python3
"""Production private-reading controls against a closed synthetic HTTP service."""
import argparse
from copy import deepcopy
import json
from pathlib import Path
import sys
import threading
from urllib.parse import urlsplit
from mock_weread import MockServer,BOOK_ID
from selection_trial_mock import Opener,credentials
from secure_native_shelf_flag_trial import NativeFlagTrialStore
from test_secure_native_session import Backend
from verify_native_shelf_flag_trial import FlagTrialProbe,TrialFailure,run

CASES=('normal','dry-run','lost-ack','empty-ack','no-mark','no-restore','changed-flag','changed-group','position-change','removed-book','host-loss')


class Server(MockServer):
    def __init__(self,case):
        super().__init__(0);self.finish_fixture=True;self.private_fixture=True;self.case=case;self.posts=[]
    def route(self,method,target,data):
        path=urlsplit(target).path
        if method=='POST' and path=='/book/secret':
            if len(self.posts)>=2 or data.get('bookIds')!=[BOOK_ID] or data.get('private')!=1-len(self.posts):raise ValueError('synthetic finish dispatch bound')
            self.posts.append(path)
            unchanged=self.case=='no-mark' and len(self.posts)==1 or self.case=='no-restore' and len(self.posts)==2
            before=self.private_flags.get(BOOK_ID,0)
            result=super().route(method,target,data)
            if unchanged:self.private_flags[BOOK_ID]=before
            if self.case=='position-change':self.control['progress_offset_delta']=1
            if self.case=='removed-book':self.shelf_removed.add(BOOK_ID)
            if self.case=='lost-ack':return 503,dict(errcode=-1)
            if self.case=='empty-ack':return 200,''
            return result
        result=super().route(method,target,data)
        if method=='GET' and path=='/shelf/sync' and self.posts:
            code,value=result;value=deepcopy(value)
            if self.case=='changed-flag':next(row for row in value['books'] if str(row['bookId'])!=BOOK_ID)['finishReading']=1
            if self.case=='changed-group':value['archive'][0]['name']='Synthetic concurrent group edit'
            return code,value
        return result


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    parser.add_argument('--case',choices=CASES,default='normal');args=parser.parse_args()
    profiles=set(Path('/dev/shm').glob('weread-private-trial-*'));server=Server(args.case)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    report=dict(result='UNVERIFIED',case=args.case,real_account_data_posts=0,authentication_posts=0)
    try:
        grant=credentials();probe=FlagTrialProbe(Opener(server));probe.prepare(grant);assert probe.bound['book_id']==BOOK_ID
        store=NativeFlagTrialStore(Backend());armed=args.case!='dry-run'
        command=[sys.executable,str(Path(__file__).with_name('run_native_shelf_flag_trial.py')),'--koreader',str(args.koreader),'--candidate',str(args.candidate),
            '--width',str(args.width),'--height',str(args.height),'--dpi',str(args.dpi),'--mock-port',str(server.server_port)]
        if armed:command.append('--armed')
        if args.case=='host-loss':
            original=probe.read
            def lost(credentials,finished):
                if finished:raise KeyboardInterrupt()
                return original(credentials,finished)
            probe.read=lost
        try:
            result=run(probe,grant,store,command,armed=armed,mock_port=server.server_port)
            assert args.case in ('normal','dry-run','lost-ack','empty-ack');report['execution']=result;assert not store.pending()
        except TrialFailure as error:
            assert args.case not in ('normal','dry-run','lost-ack','empty-ack') and store.pending()
            report.update(expected_stop=True,native_ui=error.runner,independent_steps=error.steps)
            if error.runner is not None:assert error.runner['profile_removed']
            before=len(server.posts)
            try:run(probe,grant,store,command,armed=True,mock_port=server.server_port)
            except ValueError:pass
            else:raise AssertionError('pending private-reading trial replayed')
            assert len(server.posts)==before;report['pending_replay_blocked']=True
        expected=0 if args.case=='dry-run' else 2 if args.case in ('normal','lost-ack','empty-ack','no-restore') else 1
        assert len(server.posts)==expected
        report.update(result='PASS',mock_data_posts=expected,intent_state=store.read()[0]['phase'] if store.read()[0] else 'absent')
    finally:server.shutdown();server.server_close();thread.join()
    assert set(Path('/dev/shm').glob('weread-private-trial-*'))==profiles
    for process in Path('/proc').iterdir():
        if not process.name.isdecimal():continue
        try:parts=(process/'cmdline').read_bytes().split(b'\0')
        except (OSError,ProcessLookupError):continue
        assert not any(part.endswith(b'/spec/koreader/owner_shelf_flag_trial_probe.lua') for part in parts)
    print(json.dumps(report,ensure_ascii=False,indent=2));return 0


if __name__=='__main__':raise SystemExit(main())
