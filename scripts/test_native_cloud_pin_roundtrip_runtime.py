#!/usr/bin/env python3
"""Full one-use native pin roundtrip against a closed synthetic account."""
import argparse
from copy import deepcopy
import json
from pathlib import Path
import sys
import threading
from urllib.parse import urlencode

from mock_weread import BOOK_ID
from native_cloud_pin_roundtrip import RoundtripFailure,run
from native_shelf_trial import bind
from secure_native_cloud_pin_trial import NativeCloudPinTrialStore
from secure_pin_trial import PinTrialStore,SERVICE_V3
from selection_trial_mock import credentials
from test_native_cloud_pin_runtime import Server
from test_secure_native_session import Backend
from verify_eink_login import BASE
from verify_eink_shelf_write import snapshot
from verify_native_metadata import normalize_native
from verify_owner_shelf_membership import members_digest
from verify_pin_preflight import fingerprint,reading_fingerprint

CASES=('normal','lost-ack','empty-ack','no-pin','no-unpin','changed-flag','changed-group','position-change','host-loss','dry-run-fail')

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',type=Path,required=True);parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    parser.add_argument('--case',choices=CASES,default='normal');args=parser.parse_args()
    profiles=set(Path('/dev/shm').glob('weread-cloud-pin-trial-*'))
    server=Server(args.case);server.shelf_removed.add(BOOK_ID)
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    report=dict(result='UNVERIFIED',case=args.case,real_account_data_posts=0,authentication_posts=0)
    try:
        grant=credentials();host_posts=[]
        def route(method,path,data=None):
            status,value=server.route(method,BASE+path,data or {})
            if status!=200:raise ValueError('synthetic/status')
            return deepcopy(value)
        def read():
            if args.case=='host-loss' and server.pin:raise ValueError('synthetic/host_loss')
            shelf=route('GET','/shelf/sync');progress=route('GET','/book/getProgress?'+urlencode({'bookId':BOOK_ID}))
            progress['book'].setdefault('updateTime',100)
            return {name:deepcopy(shelf) for name in ('native','web','gateway')},progress
        def send(operation):
            host_posts.append(operation)
            return route('POST','/shelf/add' if operation=='add' else '/shelf/delete',{'bookIds':[BOOK_ID]})
        shelf,progress=read();membership=dict(owner=grant['vid'],book_id=BOOK_ID,members_sha256=members_digest(snapshot(shelf['native'])),grant_sha256=fingerprint(grant))
        plan=bind(membership,shelf['native']);plans={key:deepcopy(plan) for key in ('native','web','gateway')}
        metadata=normalize_native(route('GET','/book/info?'+urlencode({'bookId':BOOK_ID})),BOOK_ID)
        outer=PinTrialStore(Backend(),service=SERVICE_V3);inner=NativeCloudPinTrialStore(Backend())
        command=[sys.executable,str(Path(__file__).with_name('run_owner_cloud_pin_trial.py')),'--koreader',str(args.koreader),
                 '--candidate',str(args.candidate if args.case!='dry-run-fail' else args.candidate.with_name('absent.zip')),
                 '--width',str(args.width),'--height',str(args.height),'--dpi',str(args.dpi),'--mock-port',str(server.server_port)]
        def execute():return run(plans,reading_fingerprint(progress),'c'*64,outer,inner,lambda:None,read,send,command,grant,metadata,mock_port=server.server_port)
        try:
            result=execute();assert args.case=='normal';report['execution']=result
            assert host_posts==['add','remove'] and len(server.posts)==2
            assert outer.read()[0]['phase']=='restored' and inner.read()[0]['phase']=='retired'
        except RoundtripFailure as error:
            assert args.case!='normal';report.update(expected_stop=True,failed_phase=error.phase,independent_steps=error.steps,native_ui=error.runner)
            expected_phase='add_verified' if args.case=='dry-run-fail' else 'unpin_pending' if args.case=='no-unpin' else 'pin_pending'
            assert error.phase==expected_phase,(error.phase,expected_phase)
            assert host_posts==['add']
            assert inner.read()[0] is None if args.case=='dry-run-fail' else inner.pending()
            before=(len(host_posts),len(server.posts))
            try:execute()
            except ValueError:pass
            else:raise AssertionError('replay allowed')
            assert before==(len(host_posts),len(server.posts));report['pending_replay_blocked']=True
        expected=0 if args.case=='dry-run-fail' else 2 if args.case in ('normal','no-unpin') else 1
        assert len(server.posts)==expected,(args.case,len(server.posts))
        report.update(result='PASS',host_mock_posts=len(host_posts),native_mock_posts=len(server.posts),outer_intent_state=outer.read()[0]['phase'],
                      inner_intent_state=inner.read()[0]['phase'] if inner.read()[0] else 'absent')
    finally:
        server.shutdown();server.server_close();thread.join()
    assert set(Path('/dev/shm').glob('weread-cloud-pin-trial-*'))==profiles
    print(json.dumps(report,ensure_ascii=False,indent=2));return 0

if __name__=='__main__':raise SystemExit(main())
