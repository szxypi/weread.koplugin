#!/usr/bin/env python3
"""One fresh-selection trial; --apply requires a new explicit four-write grant.

Default offline. Prepare and dry-run cannot modify account data. All four
possible slots are reserved once before starting an armed native process.
"""
import argparse
import copy
import json
import secrets
import subprocess
import time

from annotation_experiment_model import valid_key,note_text
from native_trial_pipe import Frames,reply,stop,write_initial
from run_native_selection_trial import validate_payload,validate_stage
from secure_native_session import NativeSessionStore
from secure_native_thought_trial import NativeThoughtTrialStore
from secure_selection_trial import SelectionTrialStore
from secure_weread_session import SessionStore
from selection_trial_model import fingerprint
from selection_trial_probe import SelectionProbe
from verify_native_thought_trial import other_pending
from verify_owner_reading import validate_cookies
from verify_translation_preflight import save_refreshed_web_session


class TrialFailure(ValueError):
    def __init__(self,runner):super().__init__('selection_trial/unverified');self.runner=runner


def validate_runner(value,armed,complete=True):
    if (not isinstance(value,dict) or set(value)!={'result','profile_removed','installed_files','installed_bytes_match','stage','cookies'}
            or value['result'] not in ('PASS','UNVERIFIED') or type(value['profile_removed']) is not bool
            or type(value['installed_bytes_match']) is not bool or type(value['installed_files']) is not int or not 0<=value['installed_files']<=1000
            or not isinstance(value['cookies'],dict)):raise ValueError('selection_trial/runner')
    if value['stage'] is not None:validate_stage(value['stage'],armed,complete)
    if complete and (value['result']!='PASS' or not value['profile_removed'] or not value['installed_bytes_match']
            or not value['installed_files'] or value['stage'] is None):raise ValueError('selection_trial/runner')
    return value


def public_runner(value):
    return None if value is None else {k:v for k,v in value.items() if k!='cookies'}


def run(probe,credentials,store,receipt,command,*,armed=False,expected=None,mock_port=None,on_final=None):
    if type(armed) is not bool or not command or any(not isinstance(x,str) or not x for x in command):raise ValueError('selection_trial/command')
    state,current=store.read();probe.current()
    if (state is None or current!=receipt or state['phase']!='prepared' or state['plan']!=probe.plan.bound
            or expected!=fingerprint(state['plan'])):raise ValueError('selection_trial/intent')
    probe.baseline(credentials,'selection_trial_before_launch')
    payload=copy.deepcopy(probe.payload)
    payload['selection_trial']=dict(armed=armed,rpc_token=secrets.token_hex(16),original_ids=sorted(probe.plan.baseline['thoughts']),
        edited_text=note_text(probe.plan.bound['nonce'],True))
    if mock_port is not None:payload['selection_mock_port']=mock_port
    validate_payload(payload,armed,mock_port)
    if armed:receipt=store.claim(receipt)
    child=frames=None;runner=None;awaiting=None;steps=0;blocked=False
    try:
        child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
        write_initial(child.stdin,payload);frames=Frames(child.stdout,payload['selection_trial']['rpc_token'],timeout=600)
        while True:
            kind,value=frames.next()
            if kind=='RESULT':runner=validate_runner(value,armed,False);validate_runner(runner,armed);break
            awaiting=value.get('seq')
            if not armed:
                if blocked or set(value)!={'seq','preview'} or type(value['seq']) is not int or value['seq']!=0 or value['preview']!=payload['selection_preview']['body']:
                    raise ValueError('selection_trial/preview')
                probe.baseline(credentials,'selection_trial_blocked');blocked=True;reply(child.stdin,dict(seq=0,ok=True));awaiting=None;continue
            if (set(value)!={'seq','created_id'} or type(value['seq']) is not int or value['seq']!=steps+1 or not 1<=value['seq']<=3
                    or not valid_key(value['created_id']) or value['created_id'] in probe.plan.baseline['thoughts']):raise ValueError('selection_trial/step')
            mark=probe.read_step(credentials,value['seq'],value['created_id'])
            receipt=store.native_step(receipt,value['seq'],value['created_id'],mark);steps=value['seq']
            if steps==3:receipt=probe.cleanup(credentials,store,receipt)
            reply(child.stdin,dict(seq=steps,ok=True,created_id=value['created_id']));awaiting=None
        if child.wait(timeout=15) or steps!=(3 if armed else 0) or blocked is armed:raise ValueError('selection_trial/child')
        validate_cookies(runner['cookies'],probe.plan.bound['owner']);probe.final(credentials,runner['cookies'])
        if on_final is not None:on_final()
        if armed:
            receipt=store.complete(receipt);store.finish(receipt)
            if store.pending():raise ValueError('selection_trial/cleanup')
        elif store.read()!=(state,current):raise ValueError('selection_trial/intent_changed')
        return dict(result='PASS',mode='apply' if armed else 'dry-run',native_ui=public_runner(runner),independent_native_steps=steps,
            reserved_posts=4 if armed else 0,cleanup_posts=probe.cleanup_posts,original_records_restored=True,
            account_data_posts=3+probe.cleanup_posts if armed else 0,
            original_state_unchanged=not probe.derived_chapter_metadata_changed,derived_chapter_metadata_changed=probe.derived_chapter_metadata_changed,
            intent_state='absent' if armed else 'prepared',no_automatic_replay=True)
    except Exception:
        if child is not None and frames is not None and child.poll() is None and awaiting is not None:
            try:
                reply(child.stdin,dict(seq=awaiting,ok=False));frames.deadline=time.monotonic()+15
                kind,value=frames.next()
                if kind=='RESULT':runner=validate_runner(value,armed,False)
                child.wait(timeout=10)
            except Exception:pass
        raise TrialFailure(public_runner(runner)) from None
    finally:
        if child is not None:stop(child)
        payload.clear()


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    modes=parser.add_mutually_exclusive_group()
    for name in ('prepare','dry-run','apply','status','discard-prepared'):modes.add_argument('--'+name,action='store_true')
    parser.add_argument('--expected-intent');parser.add_argument('--native-ui-command',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0);probe=None;saved=credentials=None;phase='init'
    try:
        if args.saved_session:
            store=SelectionTrialStore();state,receipt=store.read()
            if args.status:
                report.update(result='PASS',intent_state=state['phase'] if state else 'absent',reserved_posts=state['reserved_posts'] if state else 0,
                    native_steps=state['native_steps'] if state else 0,cleanup_pending=state['cleanup_pending'] if state else False)
            elif args.discard_prepared:
                if not state or state['phase']!='prepared' or args.expected_intent!=fingerprint(state['plan']):raise ValueError('selection_trial/intent')
                store.finish(receipt,discard_prepared=True);report.update(result='PASS',intent_state='absent')
            else:
                if not (args.prepare or args.dry_run or args.apply) or other_pending() or NativeThoughtTrialStore().pending():raise ValueError('selection_trial/mode')
                if args.prepare:
                    if state is not None:raise ValueError('selection_trial/exists')
                elif state is None or state['phase']!='prepared' or args.expected_intent!=fingerprint(state['plan']) or not args.native_ui_command:raise ValueError('selection_trial/intent')
                phase='load_session';session=SessionStore();saved=session.load();credentials=NativeSessionStore().load(saved['vid'])
                probe=SelectionProbe();phase='preflight';plan=probe.prepare(saved,credentials,state['plan'] if state else None)
                probe.web.verify_account();report['preflight_rotation_saved']=save_refreshed_web_session(session,saved,probe.web);saved=session.load()
                probe.payload['cookies']=saved['cookies']
                if args.prepare:
                    phase='save_intent';store.prepare(plan.bound)
                    report.update(result='PASS',intent_state='prepared',intent_fingerprint=fingerprint(plan.bound),maximum_posts=4,native_note_posts=3,optional_new_mark_cleanup_posts=1)
                else:
                    # CLI options never substitute for the user's new bounded grant.
                    def persist():save_refreshed_web_session(session,saved,probe.web)
                    phase='native_ui';report=run(probe,credentials,store,receipt,args.native_ui_command,armed=args.apply,expected=args.expected_intent,on_final=persist)
                    if not args.apply:report['account_data_posts']=0
                report['authentication_posts']=0
        elif any((args.prepare,args.dry_run,args.apply,args.status,args.discard_prepared,args.expected_intent,args.native_ui_command)):raise ValueError('selection_trial/offline')
    except (Exception,KeyboardInterrupt) as exc:
        report=dict(result='UNVERIFIED',mode='apply' if args.apply else 'read-only',phase=phase,no_automatic_replay=True,authentication_posts=0)
        if isinstance(exc,TrialFailure):report['native_ui']=exc.runner
        if not args.apply:report['account_data_posts']=0
        try:
            value,_receipt=SelectionTrialStore().read()
            report.update(intent_state=value['phase'] if value else 'absent',reserved_posts=value['reserved_posts'] if value else 0,
                native_steps=value['native_steps'] if value else 0,cleanup_pending=value['cleanup_pending'] if value else False)
        except Exception:report['intent_state']='unverified'
    finally:
        if probe:
            report['native_stages']=[{k:r[k] for k in ('stage','status','error_code') if k in r} for r in probe.notes.report['stages']]
            report['web_stages']=[{k:r[k] for k in ('stage','status','api_code') if k in r} for r in probe.web.report['stages']]
            report['cleanup_posts']=probe.cleanup_posts
            report['cleanup_stages']=[{k:r[k] for k in ('stage','status','error_code') if k in r} for r in probe.writer.report['stages']]
            probe.web.shards.clear();probe.web.close()
        for value in (saved,credentials):
            if value:value.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
