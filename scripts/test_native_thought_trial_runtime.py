#!/usr/bin/env python3
"""Opt-in loopback native UI trial, never a real account or public Internet."""
import argparse
import json
from pathlib import Path
import sys

from annotation_experiment_model import fingerprint
from native_thought_trial_mock import Server,Opener
from secure_native_thought_trial import NativeThoughtTrialStore
from test_secure_native_session import Backend,credentials
from verify_annotation_experiment import AnnotationProbe
from verify_native_thought_trial import TrialFailure,run


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--koreader',required=True,type=Path);parser.add_argument('--candidate',required=True,type=Path)
    parser.add_argument('--width',type=int,default=600);parser.add_argument('--height',type=int,default=800);parser.add_argument('--dpi',type=int,default=167)
    parser.add_argument('--case',choices=['normal','lost-ack','public','changed-original','host-mismatch','host-loss','dry-run'],default='normal');args=parser.parse_args(argv)
    report=dict(result='UNVERIFIED',case=args.case,posts=0,reserved_posts=0,verified_steps=0,intent_state='absent',denied=0)
    before_profiles=set(Path('/dev/shm').glob('weread-native-thought-*'))
    with Server('normal' if args.case in ('dry-run','host-loss') else args.case) as server:
        probe=AnnotationProbe(Opener(server.port),sleep=lambda _delay:None);plan=probe.prepare(credentials())
        store=NativeThoughtTrialStore(Backend());receipt=store.prepare(plan.bound)
        command=[sys.executable,str(Path(__file__).with_name('run_native_thought_trial.py')),'--koreader',str(args.koreader),'--candidate',str(args.candidate),
            '--width',str(args.width),'--height',str(args.height),'--dpi',str(args.dpi),'--mock-port',str(server.port)]
        if args.case!='dry-run':command.append('--armed')
        if args.case=='host-loss':
            def lost_host(*_args,**_kwargs):raise KeyboardInterrupt()
            probe.readback=lost_host
        try:
            result=run(probe,credentials(),store,receipt,command,armed=args.case!='dry-run',expected=fingerprint(plan.bound),mock_port=server.port)
            if args.case not in ('normal','lost-ack','dry-run'):raise AssertionError('fault accepted')
            report.update(result='PASS',native_ui=result['native_ui'],independent_steps=result['independent_steps'],original_state_unchanged=result['original_state_unchanged'])
        except TrialFailure as failure:
            state,receipt=store.read()
            if (args.case in ('public','changed-original','host-mismatch') and state['phase']=='pending' and len(server.posts)==1 and state['verified_steps']==0
                    and failure.runner is not None and failure.runner['profile_removed']):
                # A new invocation must refuse before any process launch/POST.
                count=len(server.posts)
                try:run(probe,credentials(),store,receipt,command,armed=True,expected=fingerprint(plan.bound),mock_port=server.port)
                except ValueError:pass
                else:raise AssertionError('pending replay accepted')
                assert len(server.posts)==count
                report.update(result='PASS',stopped_after_create=True,pending_replay_blocked=True,native_ui=failure.runner)
        except KeyboardInterrupt:
            state,receipt=store.read()
            assert args.case=='host-loss' and len(server.posts)==1 and state['phase']=='pending' and state['verified_steps']==0
            assert set(Path('/dev/shm').glob('weread-native-thought-*'))==before_profiles
            for process in Path('/proc').iterdir():
                if not process.name.isdecimal():continue
                try:parts=(process/'cmdline').read_bytes().split(b'\0')
                except (OSError,ProcessLookupError):continue
                assert not any(part.endswith(b'/spec/koreader/owner_thought_trial_probe.lua') for part in parts)
            report.update(result='PASS',stopped_after_create=True,host_loss_profile_removed=True,host_loss_workers_reaped=True)
        state,_receipt=store.read();report.update(posts=len(server.posts),denied=server.denied,
            reserved_posts=state['reserved_posts'] if state else 0,verified_steps=state['verified_steps'] if state else 3,
            intent_state=state['phase'] if state else 'absent')
        if server.denied:report['result']='UNVERIFIED'
    print(json.dumps(report,indent=2));return int(report['result']!='PASS')


if __name__=='__main__':raise SystemExit(main())
