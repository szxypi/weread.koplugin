#!/usr/bin/env python3
"""Prepare/dry-run native private-thought UI; apply requires a new bounded grant.

Default is offline. --prepare binds a fresh read-only baseline in Keychain.
--dry-run exercises creation but blocks dispatch. --apply reserves all three
slots once, then independently reads each step before the UI may continue.
A pending reservation cannot be relaunched, including after a zero-write crash.
"""
import argparse
from datetime import datetime,timezone
import json
import secrets
import subprocess
import time

from annotation_experiment_model import fingerprint,note_text,valid_key
from native_trial_pipe import Frames,reply,stop,write_initial
from run_native_thought_trial import validate_stage
from secure_native_thought_trial import NativeThoughtTrialStore
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from secure_annotation_experiment import AnnotationExperimentStore
from secure_highlight_trial import HighlightTrialStore
from secure_mark_style_trial import MarkStyleTrialStore
from secure_initial_mark_style import InitialMarkStyleStore
from secure_mark_color import MarkColorStore
from secure_nonempty_marks_trial import NonemptyMarksStore
from secure_readtime_trial import ReadtimeTrialStore
from secure_bookmark_trial import BookmarkTrialStore
from secure_finish_experiment import FinishExperimentStore
from secure_shelf_experiment import ShelfExperimentStore
from secure_native_shelf_trial import NativeShelfTrialStore
from secure_native_finish_trial import NativeFinishTrialStore
from secure_shelf_flag_trial import FlagTrialStore
from secure_native_shelf_flag_trial import NativeFlagTrialStore
from secure_txt_full_summary import TxtFullSummaryStore
from secure_position_experiment import ExperimentStore as PositionExperimentStore
from verify_annotation_experiment import AnnotationProbe


class TrialFailure(ValueError):
    """Fixed public failure; captured reports have already passed a schema."""
    def __init__(self,runner):
        super().__init__('native_trial/unverified');self.runner=runner


def partial_runner(value,armed):
    if (not isinstance(value,dict) or set(value)!={'result','profile_removed','installed_bytes_match','installed_files','stage'}
            or value['result'] not in ('PASS','UNVERIFIED') or type(value['profile_removed']) is not bool
            or type(value['installed_bytes_match']) is not bool or type(value['installed_files']) is not int or not 0<=value['installed_files']<=1000):raise ValueError('native_trial/runner')
    if value['stage'] is not None:validate_stage(value['stage'],armed,complete=False)
    return value


def make_payload(probe,credentials,armed,*,mock_port=None):
    probe.current();plan=probe.plan;now=int(datetime.now(timezone.utc).timestamp());baseline=plan.baseline
    value=dict(rpc_token=secrets.token_hex(16),permit_writes=armed,credentials=credentials,owner=plan.bound['owner'],book_id=plan.bound['book_id'],
        shelf_books=len(baseline['shelf']),original_ids=sorted(baseline['thoughts']),bookmark_id=plan.bound['bookmark_id'],
        marks=dict(schema=1,book_id=plan.bound['book_id'],fetched_at=now,updated=list(baseline['marks']['updated'].values()),chapters=list(baseline['marks']['chapters'].values())),
        thoughts=dict(schema=1,book_id=plan.bound['book_id'],fetched_at=now,reviews=list(baseline['thoughts'].values())),
        create_body=dict(plan.context,content=note_text(plan.bound['nonce'])),edited_text=note_text(plan.bound['nonce'],True))
    if mock_port is not None:
        if type(mock_port) is not int or not 1<=mock_port<=65535 or credentials['vid']!='900000' or credentials['accessToken']!='synthetic-native-access' or plan.bound['book_id']!='41':raise ValueError('native_trial/mock')
        value['mock_port']=mock_port
    return value


def validate_runner(value,armed):
    if (not isinstance(value,dict) or set(value)!={'result','profile_removed','installed_bytes_match','installed_files','stage'}
            or value['result']!='PASS' or value['profile_removed'] is not True or value['installed_bytes_match'] is not True
            or type(value['installed_files']) is not int or not 1<=value['installed_files']<=1000):raise ValueError('native_trial/runner')
    validate_stage(value['stage'],armed)
    return value


def run(probe,credentials,store,receipt,command,*,armed=False,expected=None,mock_port=None):
    """No Python POST exists here; every data request is the real native UI."""
    if type(armed) is not bool or not command or any(not isinstance(x,str) or not x for x in command):raise ValueError('native_trial/command')
    state,current=store.read()
    if state is None or current!=receipt or state['phase']!='prepared' or state['plan']!=probe.plan.bound or expected!=fingerprint(state['plan']):raise ValueError('native_trial/intent')
    if probe.observe(credentials,'native_before_launch')!=probe.plan.baseline:raise ValueError('native_trial/preflight')
    payload=make_payload(probe,credentials,armed,mock_port=mock_port)
    if armed:receipt=store.claim(receipt)
    child=None;steps=0;blocked=False;runner=None;frames=None;awaiting=None
    try:
        child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
        write_initial(child.stdin,payload);frames=Frames(child.stdout,payload['rpc_token'],timeout=360)
        while True:
            kind,value=frames.next()
            if kind=='RESULT':runner=partial_runner(value,armed);validate_runner(runner,armed);break
            awaiting=value.get('seq')
            if not armed:
                if blocked or set(value)!={'seq','preview'} or type(value['seq']) is not int or value['seq']!=0 or value['preview']!=payload['create_body']:raise ValueError('native_trial/preview')
                if probe.observe(credentials,'native_blocked')!=probe.plan.baseline:raise ValueError('native_trial/changed')
                blocked=True;reply(child.stdin,dict(seq=0,ok=True));awaiting=None;continue
            if (set(value)!={'seq','created_id'} or type(value['seq']) is not int or value['seq']!=steps+1 or not 1<=value['seq']<=3
                    or not valid_key(value['created_id']) or value['created_id'] in probe.plan.baseline['thoughts']
                    or steps and value['created_id']!=probe.created_id):raise ValueError('native_trial/step')
            sequence=value['seq'];row=probe.readback(credentials,('created','edited','deleted')[sequence-1],edited=sequence==2)
            if sequence==1:
                if row['reviewId']!=value['created_id']:raise ValueError('native_trial/target')
                probe.created_id=row['reviewId']
            receipt=store.verified_step(receipt,sequence,value['created_id']);steps=sequence
            reply(child.stdin,dict(seq=sequence,ok=True,created_id=value['created_id']))
            awaiting=None
        if child.wait(timeout=15):raise ValueError('native_trial/child')
        if steps!=(3 if armed else 0) or blocked is armed:raise ValueError('native_trial/steps')
        if probe.observe(credentials,'native_final')!=probe.plan.baseline:raise ValueError('native_trial/final')
        if armed:
            receipt=store.complete(receipt);store.finish(receipt)
            if store.pending():raise ValueError('native_trial/cleanup')
        elif store.read()!=(state,current):raise ValueError('native_trial/intent_changed')
        return dict(result='PASS',mode='apply' if armed else 'dry-run',native_ui=runner,independent_steps=steps,
            reserved_posts=3 if armed else 0,original_state_unchanged=True,intent_state='absent' if armed else 'prepared',
            no_automatic_replay=True)
    except Exception:
        # A rejected independent read releases no next action. Ask the waiting
        # root to exit and let its supervisor audit/remove the private profile.
        if child is not None and frames is not None and child.poll() is None and awaiting is not None:
            try:
                reply(child.stdin,dict(seq=awaiting,ok=False));frames.deadline=time.monotonic()+15
                kind,value=frames.next()
                if kind=='RESULT':runner=partial_runner(value,armed)
                child.wait(timeout=10)
            except Exception:pass
        raise TrialFailure(runner) from None
    finally:
        if child is not None:stop(child)
        payload.clear()


def readtime_pending():
    for version in (1,2):
        state,_receipt=ReadtimeTrialStore(version=version).read()
        if state is not None and state['phase']!='retired':return True
    return False


def other_pending(*,exclude_native_highlight=False,exclude_bookmark=False,exclude_native_bookmark=False,exclude_native_shelf=False,exclude_native_finish=False,exclude_mark_color=False,exclude_txt_full_summary=False):
    return (any(item.pending() for item in (AnnotationExperimentStore(),FinishExperimentStore(),ShelfExperimentStore(),PositionExperimentStore()))
            or not exclude_native_shelf and NativeShelfTrialStore().pending()
            or not exclude_native_finish and NativeFinishTrialStore().pending()
            or FlagTrialStore().pending() or NativeFlagTrialStore().pending() or not exclude_txt_full_summary and TxtFullSummaryStore().pending()
            or InitialMarkStyleStore().read()[0] is not None
            or NonemptyMarksStore().read()[0] is not None
            or readtime_pending()
            or not exclude_mark_color and MarkColorStore().read()[0] is not None
            or any(MarkStyleTrialStore(native=kind).read()[0] is not None for kind in (False,True))
            or any(BookmarkTrialStore(native=kind).read()[0] is not None for kind in (False,True)
                if not (exclude_native_bookmark if kind else exclude_bookmark))
            or any(HighlightTrialStore(native=kind).read()[0] is not None for kind in ((False,) if exclude_native_highlight else (False,True))))


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    mode=parser.add_mutually_exclusive_group();mode.add_argument('--prepare',action='store_true');mode.add_argument('--dry-run',action='store_true');mode.add_argument('--apply',action='store_true');mode.add_argument('--status',action='store_true');mode.add_argument('--discard-prepared',action='store_true')
    parser.add_argument('--expected-intent');parser.add_argument('--native-ui-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv);report=dict(result='OFFLINE',data_writes_attempted=0,authentication_posts_attempted=0);credentials={};probe=None;phase='init'
    try:
        if args.saved_session:
            store=NativeThoughtTrialStore();state,receipt=store.read()
            if args.status:
                report.update(result='PASS',intent_state=state['phase'] if state else 'absent',reserved_posts=state['reserved_posts'] if state else 0,verified_steps=state['verified_steps'] if state else 0)
            elif args.discard_prepared:
                if not state or state['phase']!='prepared' or args.expected_intent!=fingerprint(state['plan']):raise ValueError('native_trial/intent')
                store.finish(receipt,discard_prepared=True);report.update(result='PASS',intent_state='absent')
            else:
                if not (args.prepare or args.dry_run or args.apply) or other_pending():raise ValueError('native_trial/mode')
                if args.prepare:
                    if state is not None:raise ValueError('native_trial/exists')
                elif state is None or state['phase']!='prepared' or args.expected_intent!=fingerprint(state['plan']) or not args.native_ui_command:raise ValueError('native_trial/intent')
                phase='load_session';credentials=NativeSessionStore().load(SessionStore().load()['vid']);probe=AnnotationProbe();phase='preflight'
                plan=probe.prepare(credentials,existing=state['plan'] if state else None)
                if args.prepare:
                    phase='save_intent';receipt=store.prepare(plan.bound);report.update(result='PASS',intent_state='prepared',intent_fingerprint=fingerprint(plan.bound),planned_post_limit=3)
                else:
                    # A CLI flag does not confer permission. The operator must
                    # obtain a new bounded user grant before invoking --apply.
                    phase='native_ui';report=run(probe,credentials,store,receipt,args.native_ui_command,armed=args.apply,expected=args.expected_intent)
                report.update(independent_gets=probe.gets,authentication_posts_attempted=0)
                if not args.apply:report['data_writes_attempted']=0
        elif any((args.prepare,args.dry_run,args.apply,args.status,args.discard_prepared,args.expected_intent,args.native_ui_command)):raise ValueError('native_trial/offline')
    except (Exception,KeyboardInterrupt):
        # An armed failure can have an unknown dispatch count. Do not report 0.
        report=dict(result='UNVERIFIED',mode='apply' if args.apply else 'read-only',phase=phase,no_automatic_replay=True,authentication_posts_attempted=0)
        if probe is not None:
            statuses=[item.get('status') for item in probe.report['stages'] if type(item.get('status')) is int and 100<=item['status']<=599]
            report.update(independent_gets=probe.gets,last_http_status=statuses[-1] if statuses else 0)
        if not args.apply:report['data_writes_attempted']=0
        try:
            state,_receipt=NativeThoughtTrialStore().read()
            report.update(intent_state=state['phase'] if state else 'absent',reserved_posts=state['reserved_posts'] if state else 0,verified_steps=state['verified_steps'] if state else 0)
        except Exception:report['intent_state']='unverified'
    finally:credentials.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
