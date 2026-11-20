#!/usr/bin/env python3
"""Opt-in native two-step test against a closed synthetic service only."""
import argparse
from copy import deepcopy
import json
from pathlib import Path
import sys
from native_highlight_mock import Server,Opener,Web,credentials
from secure_highlight_trial import HighlightTrialStore
from selection_trial_probe import SelectionProbe
from test_secure_native_session import Backend
from verify_annotation_experiment import AnnotationProbe
from verify_eink_login import NativeProbe
from verify_highlight_trial import HighlightProbe
from verify_native_highlight_trial import run,TrialFailure

CASES=('normal','lost-ack','no-create','no-delete','changed-original','new-chapter-metadata','host-mismatch','host-loss','host-lag','dry-run','last-chapter')


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',required=True,type=Path);parser.add_argument('--candidate',required=True,type=Path)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    parser.add_argument('--case',choices=CASES,default='normal');args=parser.parse_args()
    profiles=set(Path('/dev/shm').glob('weread-reading-*'));report=dict(result='UNVERIFIED',case=args.case)
    with Server(args.case) as server:
        source=SelectionProbe(Web(server),AnnotationProbe(Opener(server),sleep=lambda _n:None),NativeProbe(Opener(server)),sleep=lambda _n:None)
        probe=HighlightProbe(source,HighlightTrialStore(Backend()),sleep=lambda _n:None)
        probe.prepare(dict(vid='900000',cookies=dict(wr_vid='900000',wr_skey='mock_key')),credentials())
        store=HighlightTrialStore(Backend(),native=True)
        command=[sys.executable,str(Path(__file__).with_name('run_native_selection_trial.py')),'--highlights','--koreader',str(args.koreader),'--candidate',str(args.candidate),
            '--width',str(args.width),'--height',str(args.height),'--dpi',str(args.dpi),'--mock-port',str(server.server_port)]
        armed=args.case!='dry-run'
        if armed:command.append('--armed')
        if args.case in ('host-mismatch','host-loss'):
            def conflict(*_args,**_kwargs):
                if args.case=='host-loss':raise KeyboardInterrupt()
                raise ValueError('synthetic host mismatch')
            probe.read=conflict
        if args.case=='host-lag':
            observe=source.notes.observe;lag=[]
            def delayed(grant,stage):
                if stage=='highlight_trial_readback' and not lag:lag.append(True);return deepcopy(source.plan.baseline)
                return observe(grant,stage)
            source.notes.observe=delayed
        try:
            result=run(probe,credentials(),store,command,armed=armed,mock_port=server.server_port)
            assert args.case in ('normal','lost-ack','new-chapter-metadata','host-lag','dry-run','last-chapter')
            report.update(execution=result)
        except TrialFailure as failure:
            assert args.case in ('no-create','no-delete','changed-original','host-mismatch','host-loss')
            state,_receipt=store.read();assert state['phase'] in ('create_pending','delete_pending') and state['reserved_posts']==2
            if failure.runner is not None:assert failure.runner['profile_removed']
            count=len(server.posts)
            try:run(probe,credentials(),store,command,armed=True,mock_port=server.server_port)
            except ValueError:pass
            else:raise AssertionError('pending reservation replayed')
            assert len(server.posts)==count
            report.update(expected_stop=True,pending_replay_blocked=True,native_ui=failure.runner)
        assert set(Path('/dev/shm').glob('weread-reading-*'))==profiles
        for process in Path('/proc').iterdir():
            if not process.name.isdecimal():continue
            try:parts=(process/'cmdline').read_bytes().split(b'\0')
            except (OSError,ProcessLookupError):continue
            assert not any(part.endswith(b'/spec/koreader/owner_reading_probe.lua') for part in parts)
        state,_receipt=store.read()
        report.update(result='PASS',mock_data_posts=len(server.posts),denied=server.trial_denied,intent_state=state['phase'] if state else 'absent',
            profile_removed=True,workers_reaped=True,real_account_data_posts=0)
        assert not server.trial_denied
    print(json.dumps(report,ensure_ascii=False,indent=2));return 0


if __name__=='__main__':raise SystemExit(main())
