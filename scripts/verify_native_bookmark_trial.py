#!/usr/bin/env python3
"""One native current-viewport bookmark, at most two independently checked writes.

Offline by default. Dry-run blocks production dispatch without a reservation.
Apply reserves both slots before launch, only operates on its new record and
never relaunches a pending trial. Private values stay in captured pipes/tmpfs.
"""
import argparse
from copy import deepcopy
import json
import secrets
import subprocess
import time
from annotation_experiment_model import digest,note_text,valid_key
from bookmark_point import first_position,project,from_mark,point_range
from bookmark_reference import reference
from bookmark_trial_model import bind
from native_bookmark_trial import validate_payload,validate_stage
from native_trial_pipe import Frames,reply,stop,write_initial
from secure_bookmark_trial import BookmarkTrialStore
from secure_native_session import NativeSessionStore
from secure_native_thought_trial import NativeThoughtTrialStore
from secure_selection_trial import SelectionTrialStore
from secure_weread_session import SessionStore
from verify_bookmark_trial import BookmarkProbe
from verify_native_highlight_trial import TrialFailure,public_runner
from verify_native_thought_trial import other_pending
from verify_owner_reading import reading_position,validate_cookies
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE
from selection_trial_probe import SelectionProbe,prepare_web_handoff
from bookmark_trial_recovery import reconcile_deleted,finish_reconcile


def bind_native(selection,body):return bind(selection,body,native=True)


class NativeBookmarkProbe(BookmarkProbe):
    def prepare(self,saved,credentials):
        super().prepare(saved,credentials)
        self.first=first_position(self.raw)
        from bookmark_trial_model import request
        self.body=request(self.source.plan.context,self.raw,self.first)
        for row in self.source.plan.baseline['marks']['updated'].values():
            if row.get('type')==0 and row.get('chapterUid')==self.body['chapterUid'] and point_range(row.get('range'))==point_range(self.body['range']):
                raise ValueError('native_bookmark/existing')
        self.bound=bind(self.source.plan.bound,self.body);self.current();return self.bound

    def read(self,credentials,*,deleted=False):
        target,observed=super().read(credentials,deleted=deleted)
        if target:
            point=from_mark(self.raw,self.body['bookId'],str(self.body['chapterUid']),observed['marks']['updated'][target['id']])
            if point['chapter_offset']!=self.first:raise ValueError('native_bookmark/position')
        return target,observed


def payload(probe,armed,mock_port=None):
    probe.current();p=probe.source.plan;value=deepcopy(probe.source.payload)
    value['selection_trial']=dict(armed=armed,rpc_token=secrets.token_hex(16),original_ids=sorted(p.baseline['thoughts']),edited_text=note_text(p.bound['nonce'],True))
    value['bookmark_trial']=dict(create_body=deepcopy(probe.body),first=probe.first,original_ids=sorted(p.baseline['marks']['updated']),
        reference=reference(p.bound['book_id'],p.bound['chapter_uid'],value['selection_preview']['reference']['chapterIdx'],project(probe.raw,probe.first)))
    if mock_port is not None:value['selection_mock_port']=mock_port
    validate_payload(value,armed,mock_port);return value

def validate_runner(value,armed,complete=True):
    if (not isinstance(value,dict) or set(value)!={'result','profile_removed','installed_files','installed_bytes_match','stage','cookies'}
            or value['result'] not in ('PASS','UNVERIFIED') or type(value['profile_removed']) is not bool
            or type(value['installed_bytes_match']) is not bool or type(value['installed_files']) is not int or not 0<=value['installed_files']<=1000
            or not isinstance(value['cookies'],dict)):raise ValueError('native_highlight/runner')
    if value['stage'] is not None:validate_stage(value['stage'],armed,complete)
    if complete and (value['result']!='PASS' or not value['profile_removed'] or not value['installed_bytes_match']
            or not value['installed_files'] or value['stage'] is None):raise ValueError('native_highlight/runner')
    return value


def run(probe,credentials,store,command,*,armed=False,mock_port=None,on_final=None):
    if type(armed) is not bool or not command or any(not isinstance(v,str) or not v for v in command):raise ValueError('native_bookmark/command')
    if not store.native or store.read()!=(None,None):raise ValueError('native_bookmark/pending')
    probe.current();bound=bind_native(probe.source.plan.bound,probe.body)
    probe.source.baseline(credentials,'native_bookmark_before_launch');value=payload(probe,armed,mock_port)
    receipt=store.reserve(bound) if armed else None
    child=frames=runner=awaiting=None;steps=0;blocked=False
    try:
        child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
        write_initial(child.stdin,value);frames=Frames(child.stdout,value['selection_trial']['rpc_token'],timeout=600)
        while True:
            kind,event=frames.next()
            if kind=='RESULT':runner=validate_runner(event,armed,False);validate_runner(runner,armed);break
            awaiting=event.get('seq')
            if not armed:
                if blocked or set(event)!={'seq','preview'} or type(event['seq']) is not int or event['seq']!=0 or event['preview']!=probe.body:raise ValueError('native_bookmark/preview')
                probe.source.baseline(credentials,'native_bookmark_blocked');blocked=True
                reply(child.stdin,dict(seq=0,ok=True));awaiting=None;continue
            state,owned=store.read()
            if (owned!=receipt or state['plan']!=bound or digest(bound)!=digest(bind_native(probe.source.plan.bound,probe.body))
                    or set(event)!={'seq','created_id'} or type(event['seq']) is not int or event['seq']!=steps+1 or not 1<=event['seq']<=2
                    or not valid_key(event['created_id']) or event['created_id'] in probe.source.plan.baseline['marks']['updated']):raise ValueError('native_bookmark/step')
            if event['seq']==1:
                if state['phase']!='create_pending':raise ValueError('native_bookmark/intent')
                target,_observed=probe.read(credentials)
                if target['id']!=event['created_id']:raise ValueError('native_bookmark/target')
                probe.target=target;receipt=store.advance(receipt,'created',target=target)
                probe.read(credentials);receipt=store.advance(receipt,'delete_pending')
            else:
                if state['phase']!='delete_pending' or state['target']!=probe.target or event['created_id']!=probe.target['id']:raise ValueError('native_bookmark/target')
                probe.read(credentials,deleted=True)
            steps=event['seq'];reply(child.stdin,dict(seq=steps,ok=True,created_id=event['created_id']));awaiting=None
        if child.wait(timeout=15) or steps!=(2 if armed else 0) or blocked is armed:raise ValueError('native_bookmark/child')
        if armed:_target,final=probe.read(credentials,deleted=True)
        else:final=probe.source.baseline(credentials,'native_bookmark_final')
        web=probe.source.web;p=probe.source.plan;validate_cookies(runner['cookies'],p.bound['owner']);web.cookies.clear()
        for key,item in runner['cookies'].items():web.set_cookie(key,item)
        web.verify_account()
        after=reading_position(web.request('progress_after',BASE+'/web/book/getProgress?bookId='+p.bound['book_id']),p.bound['book_id'])
        if after!=p.web_position:raise ValueError('native_bookmark/web_position')
        if on_final:on_final()
        if armed:
            receipt=store.advance(receipt,'verified');store.finish(receipt)
        if store.read()!=(None,None):raise ValueError('native_bookmark/cleanup')
        changed=final['marks']['chapters']!=p.baseline['marks']['chapters']
        return dict(result='PASS',mode='apply' if armed else 'dry-run',native_ui=public_runner(runner),independent_steps=steps,
            reserved_posts=2 if armed else 0,account_data_posts=2 if armed else 0,authentication_posts=0,
            original_records_restored=True,web_position_unchanged=True,derived_chapter_metadata_changed=changed,original_state_unchanged=not changed,
            intent_state='absent',no_automatic_replay=True)
    except (Exception,KeyboardInterrupt):
        if child is not None and frames is not None and child.poll() is None and awaiting is not None:
            try:
                reply(child.stdin,dict(seq=awaiting,ok=False));frames.deadline=time.monotonic()+15
                kind,event=frames.next()
                if kind=='RESULT':runner=validate_runner(event,armed,False)
                child.wait(timeout=10)
            except Exception:pass
        raise TrialFailure(public_runner(runner)) from None
    finally:
        if child is not None:stop(child)
        value.clear()



def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    mode=parser.add_mutually_exclusive_group()
    for name in ('dry-run','apply','status','resolve'):mode.add_argument('--'+name,action='store_true')
    parser.add_argument('--expected-intent');parser.add_argument('--native-ui-command',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0);probe=source=saved=credentials=None;phase='init'
    try:
        if args.saved_session:
            store=BookmarkTrialStore(native=True)
            if args.status:
                state,_receipt=store.read();report.update(result='PASS',intent_state=state['phase'] if state else 'absent')
            elif args.resolve:
                if not args.expected_intent or args.native_ui_command or other_pending(exclude_native_bookmark=True) or NativeThoughtTrialStore().pending() or SelectionTrialStore().pending():
                    raise ValueError('native_bookmark/pending')
                phase='load_session';session=SessionStore();saved=session.load();credentials=NativeSessionStore().load(saved['vid'])
                phase='read_only_reconcile';probe=reconcile_deleted(saved,credentials,store,args.expected_intent)
                report=finish_reconcile(probe,credentials,on_final=lambda:save_refreshed_web_session(session,saved,probe.source.web))
            else:
                if (not (args.apply or args.dry_run) or args.expected_intent or not args.native_ui_command or store.read()!=(None,None)
                        or other_pending() or NativeThoughtTrialStore().pending() or SelectionTrialStore().pending()):raise ValueError('native_bookmark/pending')
                phase='load_session';session=SessionStore();saved=session.load();credentials=NativeSessionStore().load(saved['vid'])
                probe=NativeBookmarkProbe();phase='prepare';probe.prepare(saved,credentials)
                phase='web_handoff';saved=prepare_web_handoff(session,saved,probe.source)
                phase='native_ui';report=run(probe,credentials,store,args.native_ui_command,armed=args.apply,
                    on_final=lambda:save_refreshed_web_session(session,saved,probe.source.web))
        elif args.apply or args.dry_run or args.status or args.resolve or args.expected_intent or args.native_ui_command:raise ValueError('native_bookmark/offline')
    except (Exception,KeyboardInterrupt) as error:
        report=dict(result='UNVERIFIED',phase=phase,authentication_posts=0,no_automatic_replay=True)
        if not args.apply or phase in ('init','load_session','prepare','web_handoff'):report['account_data_posts']=0
        if isinstance(error,TrialFailure):report['native_ui']=error.runner
        if args.saved_session:
            try:
                state,_receipt=BookmarkTrialStore(native=True).read();report.update(intent_state=state['phase'] if state else 'absent',reserved_posts=state['reserved_posts'] if state else 0)
            except Exception:report['intent_state']='unverified'
    finally:
        source=probe.source if probe else source
        if source:
            for name,transport in (('native',source.notes),('web',source.web),('host_writer',source.writer)):
                report[name+'_stages']=[{k:r[k] for k in ('stage','status','error_code','api_code') if k in r} for r in transport.report['stages']]
            source.web.shards.clear();source.web.close()
        for item in (saved,credentials):
            if item:item.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
