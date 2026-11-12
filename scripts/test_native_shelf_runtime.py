#!/usr/bin/env python3
"""Closed-service native shelf trial, including host conflict and lost receipts."""
import argparse
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import sys
import threading
from urllib.parse import urlsplit
from mock_weread import MockServer,BOOK_ID
from selection_trial_mock import Opener,credentials
from test_secure_native_session import Backend
from secure_native_shelf_trial import NativeShelfTrialStore
from secure_shelf_experiment import canonical
from native_shelf_trial import bind
from verify_native_metadata import normalize_native
from verify_owner_shelf_membership import members_digest
from verify_eink_shelf_write import snapshot
from verify_native_shelf_trial import ShelfTrialProbe,TrialFailure,run

CASES=('normal','dry-run','lost-ack','no-add','no-remove','changed-flag','changed-group','host-loss')


class Server(MockServer):
    def __init__(self,case):
        super().__init__(0);self.case=case;self.posts=[];self.shelf_removed.add(BOOK_ID)

    def route(self,method,target,data):
        path=urlsplit(target).path
        if method=='POST' and path in ('/shelf/add','/shelf/delete'):
            if len(self.posts)>=2 or data!={'bookIds':[BOOK_ID]}:raise ValueError('synthetic shelf dispatch bound')
            self.posts.append(path)
            if self.case=='no-add' and path=='/shelf/add' or self.case=='no-remove' and path=='/shelf/delete':return 200,dict(succ=1)
            result=super().route(method,target,data)
            return (200,{}) if self.case=='lost-ack' else result
        result=super().route(method,target,data)
        if method=='GET' and path=='/shelf/sync':
            code,value=result;value=deepcopy(value)
            # The general display fixture deliberately includes one malformed
            # privacy flag. This write trial starts from explicitly valid flags.
            for row in value['books']:
                if str(row['bookId'])=='900003':row['secret']=0
            if self.posts and self.case=='changed-flag':
                row=next(row for row in value['books'] if str(row['bookId'])!=BOOK_ID)
                row['secret']=not bool(row.get('secret',False))
            if self.posts and self.case=='changed-group':value['archive'][0]['name']='Synthetic concurrent group change'
            return code,value
        return result


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',type=Path,required=True)
    parser.add_argument('--candidate',type=Path,required=True);parser.add_argument('--width',type=int,default=600)
    parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    parser.add_argument('--case',choices=CASES,default='normal');args=parser.parse_args()
    profiles=set(Path('/dev/shm').glob('weread-membership-*'))
    server=Server(args.case);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    report=dict(result='UNVERIFIED',case=args.case,real_account_data_posts=0,authentication_posts=0)
    try:
        grant=credentials();probe=ShelfTrialProbe(Opener(server));base='https://i.weread.qq.com'
        initial=probe.request('discovery_shelf',base+'/shelf/sync',credentials=grant)
        old=dict(owner=grant['vid'],book_id=BOOK_ID,members_sha256=members_digest(snapshot(initial)),grant_sha256=hashlib.sha256(canonical(grant)).hexdigest())
        probe.bound=bind(old,initial)
        probe.payload=dict(credentials=grant,book_id=BOOK_ID,shelf_books=len(initial['books']),members_digest=old['members_sha256'],
            expected_metadata=normalize_native(probe.request('discovery_metadata',base+'/book/info?bookId='+BOOK_ID,credentials=grant),BOOK_ID))
        store=NativeShelfTrialStore(Backend());armed=args.case!='dry-run'
        command=[sys.executable,str(Path(__file__).with_name('run_owner_shelf_membership.py')),'--host-steps','--koreader',str(args.koreader),
            '--candidate',str(args.candidate),'--width',str(args.width),'--height',str(args.height),'--dpi',str(args.dpi),'--mock-port',str(server.server_port)]
        if armed:command.append('--armed')
        if args.case=='host-loss':
            observe=probe.read
            def lost(credentials,present):
                if present:raise KeyboardInterrupt()
                return observe(credentials,present)
            probe.read=lost
        try:
            result=run(probe,grant,store,command,armed=armed,mock_port=server.server_port)
            assert args.case in ('normal','dry-run');report['execution']=result
            assert not store.pending()
        except TrialFailure as error:
            assert args.case not in ('normal','dry-run') and store.pending()
            report.update(expected_stop=True,native_ui=error.runner,independent_steps=error.steps)
            if error.runner is not None:assert error.runner['profile_removed']
            before=len(server.posts)
            try:run(probe,grant,store,command,armed=True,mock_port=server.server_port)
            except ValueError:pass
            else:raise AssertionError('pending shelf trial replayed')
            assert len(server.posts)==before;report['pending_replay_blocked']=True
        expected=0 if args.case=='dry-run' else 2 if args.case in ('normal','no-remove') else 1
        assert len(server.posts)==expected
        report.update(result='PASS',mock_data_posts=expected,intent_state='pending' if store.pending() else 'absent')
    finally:server.shutdown();server.server_close();thread.join()
    assert set(Path('/dev/shm').glob('weread-membership-*'))==profiles
    for process in Path('/proc').iterdir():
        if not process.name.isdecimal():continue
        try:parts=(process/'cmdline').read_bytes().split(b'\0')
        except (OSError,ProcessLookupError):continue
        assert not any(part.endswith(b'/spec/koreader/owner_shelf_membership_probe.lua') for part in parts)
    print(json.dumps(report,ensure_ascii=False,indent=2));return 0


if __name__=='__main__':raise SystemExit(main())
