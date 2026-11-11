#!/usr/bin/env python3
"""Four bounded native highlight/style operations with independent host reads.

Offline by default; dry-run blocks the first production transport dispatch.
Apply reserves four slots in a separate native intent, never replays pending
work, and edits only the new test highlight. Private payloads use pipes/tmpfs.
"""
import argparse
import json
import subprocess
import time
from annotation_experiment_model import digest,valid_key
from mark_style_trial_model import bind
from native_highlight_trial import validate_payload
from native_trial_pipe import Frames,reply,stop,write_initial
from secure_mark_style_trial import MarkStyleTrialStore
from secure_native_session import NativeSessionStore
from secure_native_thought_trial import NativeThoughtTrialStore
from secure_selection_trial import SelectionTrialStore
from secure_weread_session import SessionStore
from verify_mark_style_trial import StyleProbe
from verify_native_highlight_trial import payload as highlight_payload,validate_runner,public_runner,TrialFailure
from verify_native_thought_trial import other_pending
from verify_owner_reading import reading_position,validate_cookies
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE
from selection_trial_probe import prepare_web_handoff


class NativeStyleProbe(StyleProbe):
    def prepare(self,saved,credentials):
        if self.bound is not None or self.store.read()[0] is not None:raise ValueError('native_style/pending')
        self.bound=bind(self.highlight.prepare(saved,credentials),native=True);return self.bound

    def current(self):
        self.highlight.current()
        if self.bound!=bind(self.highlight.bound,native=True):raise ValueError('native_style/changed')


def payload(probe,armed,mock_port=None):
    value=highlight_payload(probe.highlight,armed,mock_port);value['highlight_trial']['styles']=True
    validate_payload(value,armed,mock_port,styles=True);return value


def run(probe,credentials,command,*,armed=False,mock_port=None,on_final=None):
    store=probe.store
    if type(armed) is not bool or not command or any(not isinstance(v,str) or not v for v in command):raise ValueError('native_style/command')
    if not store.native or store.read()!=(None,None):raise ValueError('native_style/pending')
    probe.current();p=probe.highlight.source.plan;bound=probe.bound
    probe.highlight.source.baseline(credentials,'native_style_before_launch');value=payload(probe,armed,mock_port)
    receipt=store.reserve(bound) if armed else None
    child=frames=runner=awaiting=None;steps=0;blocked=False
    try:
        child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
        write_initial(child.stdin,value);frames=Frames(child.stdout,value['selection_trial']['rpc_token'],timeout=600)
        while True:
            kind,event=frames.next()
            if kind=='RESULT':runner=validate_runner(event,armed,False,styles=True);validate_runner(runner,armed,styles=True);break
            awaiting=event.get('seq')
            if not armed:
                if blocked or set(event)!={'seq','preview'} or type(event['seq']) is not int or event['seq']!=0 or event['preview']!=probe.highlight.body:raise ValueError('native_style/preview')
                probe.highlight.source.baseline(credentials,'native_style_blocked');blocked=True
                reply(child.stdin,dict(seq=0,ok=True));awaiting=None;continue
            probe.current();state,owned=store.read()
            if (owned!=receipt or state['plan']!=bound or set(event)!={'seq','created_id'} or type(event['seq']) is not int
                    or event['seq']!=steps+1 or not 1<=event['seq']<=4 or not valid_key(event['created_id'])
                    or event['created_id'] in p.baseline['marks']['updated']):raise ValueError('native_style/step')
            sequence=event['seq'];phase={1:'create_pending',2:'straight_pending',3:'wave_pending',4:'delete_pending'}[sequence]
            if state['phase']!=phase or state['target']!=probe.target:raise ValueError('native_style/intent')
            target,row,_observed=probe.read(credentials,style={2:0,3:2}.get(sequence),deleted=sequence==4)
            if sequence<4:
                if target['id']!=event['created_id'] or probe.target is not None and target['id']!=probe.target['id']:raise ValueError('native_style/target')
                probe.target,probe.row=target,row
                receipt=store.advance(receipt,{1:'created',2:'straight',3:'wave'}[sequence],target=target)
                probe.read(credentials,style=row['style'])
                receipt=store.advance(receipt,{1:'straight_pending',2:'wave_pending',3:'delete_pending'}[sequence])
            elif event['created_id']!=probe.target['id']:raise ValueError('native_style/target')
            steps=sequence;reply(child.stdin,dict(seq=sequence,ok=True,created_id=event['created_id']));awaiting=None
        if child.wait(timeout=15) or steps!=(4 if armed else 0) or blocked is armed:raise ValueError('native_style/child')
        if armed:_target,_row,final=probe.read(credentials,deleted=True)
        else:final=probe.highlight.source.baseline(credentials,'native_style_final')
        web=probe.highlight.source.web;validate_cookies(runner['cookies'],p.bound['owner']);web.cookies.clear()
        for key,item in runner['cookies'].items():web.set_cookie(key,item)
        web.verify_account()
        after=reading_position(web.request('progress_after',BASE+'/web/book/getProgress?bookId='+p.bound['book_id']),p.bound['book_id'])
        if after!=p.web_position:raise ValueError('native_style/web_position')
        if on_final:on_final()
        if armed:receipt=store.advance(receipt,'verified');store.finish(receipt)
        if store.read()!=(None,None):raise ValueError('native_style/cleanup')
        return dict(result='PASS',mode='apply' if armed else 'dry-run',native_ui=public_runner(runner),independent_steps=steps,
            reserved_posts=4 if armed else 0,account_data_posts=4 if armed else 0,authentication_posts=0,
            original_records_restored=True,web_position_unchanged=True,color_setting_preserved=True,
            derived_chapter_metadata_changed=final['marks']['chapters']!=p.baseline['marks']['chapters'],
            intent_state='absent',no_automatic_replay=True)
    except (Exception,KeyboardInterrupt):
        if child is not None and frames is not None and child.poll() is None and awaiting is not None:
            try:
                reply(child.stdin,dict(seq=awaiting,ok=False));frames.deadline=time.monotonic()+15
                kind,event=frames.next()
                if kind=='RESULT':runner=validate_runner(event,armed,False,styles=True)
                child.wait(timeout=10)
            except Exception:pass
        raise TrialFailure(public_runner(runner)) from None
    finally:
        if child is not None:stop(child)
        value.clear()


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    group=parser.add_mutually_exclusive_group();group.add_argument('--dry-run',action='store_true');group.add_argument('--apply',action='store_true');group.add_argument('--status',action='store_true')
    parser.add_argument('--native-ui-command',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0);probe=saved=credentials=None;phase='init'
    try:
        if args.saved_session:
            store=MarkStyleTrialStore(native=True)
            if args.status:
                state,_receipt=store.read();report.update(result='PASS',intent_state=state['phase'] if state else 'absent')
            else:
                if other_pending() or NativeThoughtTrialStore().pending() or SelectionTrialStore().pending():raise ValueError('native_style/other_pending')
                phase='load_session';session=SessionStore();saved=session.load();credentials=NativeSessionStore().load(saved['vid'])
                probe=NativeStyleProbe(store=store);phase='prepare';probe.prepare(saved,credentials)
                phase='web_handoff';saved=prepare_web_handoff(session,saved,probe.highlight.source)
                if not args.native_ui_command or not (args.apply or args.dry_run):raise ValueError('native_style/command')
                phase='apply' if args.apply else 'dry_run'
                report=run(probe,credentials,args.native_ui_command,armed=args.apply,
                    on_final=lambda:save_refreshed_web_session(session,saved,probe.highlight.source.web))
        elif args.native_ui_command or args.apply or args.dry_run or args.status:raise ValueError('native_style/offline')
    except (Exception,KeyboardInterrupt) as error:
        report=dict(result='UNVERIFIED',phase=phase,account_data_posts=0 if phase in ('init','load_session','prepare','web_handoff') else None,
            authentication_posts=0,no_automatic_replay=True)
        if isinstance(error,TrialFailure):report['native_ui']=error.runner
        if args.saved_session:
            try:
                state,_receipt=MarkStyleTrialStore(native=True).read();report['intent_state']=state['phase'] if state else 'absent'
            except Exception:report['intent_state']='unverified'
    finally:
        if probe:
            source=probe.highlight.source
            for name,transport in [('native',source.notes),('web',source.web)]:
                report[name+'_stages']=[{k:v[k] for k in ('stage','status','error_code','api_code') if k in v} for v in transport.report['stages']]
            source.web.shards.clear();source.web.close()
        for value in (saved,credentials):
            if value:value.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
