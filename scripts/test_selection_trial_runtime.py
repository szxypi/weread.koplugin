#!/usr/bin/env python3
"""Opt-in native source trial against a closed synthetic service only."""
import argparse
import json
from pathlib import Path
import sys
from selection_trial_mock import Server,Opener,Web,credentials
from selection_trial_probe import SelectionProbe
from selection_trial_model import fingerprint
from secure_selection_trial import SelectionTrialStore
from test_secure_native_session import Backend
from verify_annotation_experiment import AnnotationProbe
from verify_eink_login import NativeProbe
from verify_selection_trial import run,TrialFailure

CASES=('normal','associated','auto-remove','lost-ack','public','changed-original','unrelated-mark','mark-changed','cleanup-no-change','new-chapter-metadata','host-mismatch','host-loss','host-lag','dry-run')


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',required=True,type=Path);parser.add_argument('--candidate',required=True,type=Path)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    parser.add_argument('--case',choices=CASES,default='normal');args=parser.parse_args()
    profiles=set(Path('/dev/shm').glob('weread-reading-*'));report=dict(result='UNVERIFIED',case=args.case)
    with Server('normal' if args.case in ('dry-run','host-loss','host-mismatch') else args.case) as server:
        probe=SelectionProbe(Web(server),AnnotationProbe(Opener(server),sleep=lambda _n:None),NativeProbe(Opener(server)),sleep=lambda _n:None)
        plan=probe.prepare(dict(vid='900000',cookies=dict(wr_vid='900000',wr_skey='mock_key')),credentials())
        store=SelectionTrialStore(Backend());receipt=store.prepare(plan.bound)
        command=[sys.executable,str(Path(__file__).with_name('run_native_selection_trial.py')),'--koreader',str(args.koreader),'--candidate',str(args.candidate),
            '--width',str(args.width),'--height',str(args.height),'--dpi',str(args.dpi),'--mock-port',str(server.server_port)]
        armed=args.case!='dry-run'
        if armed:command.append('--armed')
        if args.case in ('host-loss','host-mismatch'):
            def conflict(*values):
                if args.case=='host-loss':raise KeyboardInterrupt()
                raise ValueError('synthetic host mismatch')
            probe.read_step=conflict
        if args.case=='host-lag':
            from copy import deepcopy
            read=probe.notes.observe;lag=[]
            def lagged(grant,stage):
                if stage=='selection_trial_step_1' and not lag:
                    lag.append(True);return deepcopy(plan.baseline)
                return read(grant,stage)
            probe.notes.observe=lagged
        try:
            result=run(probe,credentials(),store,receipt,command,armed=armed,expected=fingerprint(plan.bound),mock_port=server.server_port)
            if args.case not in ('normal','associated','auto-remove','lost-ack','new-chapter-metadata','host-lag','dry-run'):raise AssertionError('fault accepted')
            report.update(result='PASS',execution=result)
        except TrialFailure as failure:
            state,current=store.read()
            if args.case not in ('public','changed-original','unrelated-mark','mark-changed','cleanup-no-change','host-mismatch'):raise
            assert state['phase']=='pending' and state['reserved_posts']==4
            if failure.runner is not None:assert failure.runner['profile_removed']
            before=len(server.posts)
            try:run(probe,credentials(),store,current,command,armed=True,expected=fingerprint(plan.bound),mock_port=server.server_port)
            except ValueError:pass
            else:raise AssertionError('replay accepted')
            assert len(server.posts)==before
            report.update(result='PASS',expected_stop=True,pending_replay_blocked=True,native_ui=failure.runner)
        except KeyboardInterrupt:
            assert args.case=='host-loss' and store.read()[0]['phase']=='pending' and len(server.posts)==1
            assert set(Path('/dev/shm').glob('weread-reading-*'))==profiles
            for process in Path('/proc').iterdir():
                if not process.name.isdecimal():continue
                try:parts=(process/'cmdline').read_bytes().split(b'\0')
                except (OSError,ProcessLookupError):continue
                assert not any(part.endswith(b'/spec/koreader/owner_reading_probe.lua') for part in parts)
            report.update(result='PASS',host_loss_cleanup=True,host_loss_workers_reaped=True)
        state,_receipt=store.read()
        report.update(posts=len(server.posts),native_posts=server.selection_posts,cleanup_posts=server.cleanup_posts,denied=server.trial_denied,
            intent_state=state['phase'] if state else 'absent',reserved_posts=state['reserved_posts'] if state else 0,native_steps=state['native_steps'] if state else 3,
            profile_removed=set(Path('/dev/shm').glob('weread-reading-*'))==profiles)
        assert report['profile_removed'] and not server.trial_denied
    print(json.dumps(report,indent=2));return int(report['result']!='PASS')


if __name__=='__main__':raise SystemExit(main())
