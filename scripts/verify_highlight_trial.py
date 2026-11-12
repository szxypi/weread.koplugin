#!/usr/bin/env python3
"""Prototype one new source highlight and removal; offline unless opted in.

--saved-session is read-only. --apply reserves two writes before dispatch,
never replays pending work, and stops on any unrelated observed change.
Private responses stay in memory. The owner's continuing development grant
covers this bounded test; command-line flags do not grant account access.
"""
import argparse
import json
import re
import time
from highlight_trial_model import bind,request,observe,PendingObservation
from secure_highlight_trial import HighlightTrialStore
from secure_native_session import NativeSessionStore
from secure_native_thought_trial import NativeThoughtTrialStore
from secure_selection_trial import SelectionTrialStore
from secure_weread_session import SessionStore
from selection_trial_probe import SelectionProbe
from verify_eink_login import BASE,ProbeError
from verify_native_thought_trial import other_pending
from verify_owner_reading import reading_position
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE as WEB


class HighlightProbe:
    def __init__(self,source=None,store=None,sleep=time.sleep):
        self.source=source or SelectionProbe();self.store=store or HighlightTrialStore();self.sleep=sleep
        self.posts=0;self.receipt=None;self.bound=None;self.body=None;self.target=None

    def prepare(self,saved,credentials):
        if self.bound is not None or self.store.read()[0] is not None:raise ValueError('highlight_trial/pending')
        p=self.source.prepare(saved,credentials);self.body=request(p.context)
        # Do not alter/attach to a pre-existing thought in this selection.
        a,b=map(int,self.body['range'].split('-'))
        for row in p.baseline['thoughts'].values():
            if str(row.get('chapterUid'))!=str(self.body['chapterUid']):continue
            marker=row.get('range','')
            if not isinstance(marker,str) or not re.fullmatch('[0-9]{1,10}-[0-9]{1,10}',marker):raise ValueError('highlight_trial/thought_range')
            start,end=map(int,marker.split('-'))
            if start<b and end>a:raise ValueError('highlight_trial/existing_thought')
        self.bound=bind(p.bound,self.body);return self.bound

    def current(self):
        self.source.current()
        if self.body!=request(self.source.plan.context) or self.bound!=bind(self.source.plan.bound,self.body):raise ValueError('highlight_trial/changed')

    def read(self,credentials,*,deleted=False):
        self.current()
        for attempt in range(3):
            if attempt:self.sleep(.5*attempt)
            value=self.source.notes.observe(credentials,'highlight_trial_readback')
            try:target=observe(self.source.plan.baseline,value,self.body,deleted=deleted,target=self.target)
            except PendingObservation:
                if attempt==2:raise
                continue
            return target,value
        raise ValueError('highlight_trial/readback')

    def post(self,credentials,phase,path,body):
        self.current()
        state,owned=self.store.read()
        if (owned!=self.receipt or state is None or state['plan']!=self.bound or state['phase']!=phase
                or self.posts!=int(phase=='delete_pending') or not self.store.owns(self.receipt,phase)
                or phase=='delete_pending' and (self.target!=state['target'] or self.target['id'] in self.source.plan.baseline['marks']['updated'])
                or (path,body)!=(( '/book/addBookmark',self.body) if phase=='create_pending' else
                                ('/book/removeBookmark',dict(bookmarkIds=[self.target['id']])))):
            raise ValueError('highlight_trial/dispatch')
        self.posts+=1
        # One dispatch only. A missing HTTP/JSON receipt is independently read;
        # a matching new record is required before any deletion is possible.
        try:self.source.writer.request('highlight_trial_'+phase,BASE+path,body,credentials)
        except ProbeError:pass

    def run(self,credentials,*,apply=False):
        self.current();self.source.baseline(credentials,'highlight_trial_before')
        p=self.source.plan
        if apply:
            self.receipt=self.store.reserve(self.bound)
            self.post(credentials,'create_pending','/book/addBookmark',self.body)
            self.target,_created=self.read(credentials)
            self.receipt=self.store.advance(self.receipt,'created',target=self.target)
            # Re-read the entire state immediately before claiming removal.
            self.read(credentials)
            self.receipt=self.store.advance(self.receipt,'delete_pending')
            self.post(credentials,'delete_pending','/book/removeBookmark',dict(bookmarkIds=[self.target['id']]))
            _target,final=self.read(credentials,deleted=True)
        else:final=self.source.baseline(credentials,'highlight_trial_readonly')
        self.source.web.verify_account()
        after=reading_position(self.source.web.request('progress_after',WEB+'/web/book/getProgress?bookId='+p.bound['book_id']),p.bound['book_id'])
        if after!=p.web_position:raise ValueError('highlight_trial/web_position')
        if apply:
            self.receipt=self.store.advance(self.receipt,'verified');self.store.finish(self.receipt)
            if self.store.read()[0] is not None:raise ValueError('highlight_trial/cleanup')
        changed=final['marks']['chapters']!=p.baseline['marks']['chapters']
        return dict(result='PASS',mode='apply' if apply else 'read-only',account_data_posts=self.posts,
                    independent_steps=2 if apply else 0,original_records_restored=True,web_position_unchanged=True,
                    derived_chapter_metadata_changed=changed,original_state_unchanged=not changed,
                    intent_state='absent',no_automatic_replay=True)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    mode=parser.add_mutually_exclusive_group();mode.add_argument('--apply',action='store_true');mode.add_argument('--status',action='store_true');args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0);probe=None;saved=credentials=None;phase='init'
    try:
        if args.saved_session:
            store=HighlightTrialStore()
            if args.status:
                state,_receipt=store.read();report.update(result='PASS',intent_state=state['phase'] if state else 'absent')
            else:
                if other_pending() or NativeThoughtTrialStore().pending() or SelectionTrialStore().pending():raise ValueError('highlight_trial/other_pending')
                phase='load_session';session=SessionStore();saved=session.load();credentials=NativeSessionStore().load(saved['vid'])
                probe=HighlightProbe(store=store);phase='prepare';probe.prepare(saved,credentials)
                phase='apply' if args.apply else 'read_only';report=probe.run(credentials,apply=args.apply)
                phase='save_web_session';save_refreshed_web_session(session,saved,probe.source.web)
        elif args.apply or args.status:raise ValueError('highlight_trial/offline')
    except (Exception,KeyboardInterrupt):
        report=dict(result='UNVERIFIED',phase=phase,account_data_posts=probe.posts if probe else 0,no_automatic_replay=True)
        if args.saved_session:
            try:
                state,_receipt=HighlightTrialStore().read();report['intent_state']=state['phase'] if state else 'absent'
            except Exception:report['intent_state']='unverified'
        else:report['intent_state']='not_opened'
    finally:
        report['authentication_posts']=0
        if probe:
            source=probe.source
            for name,transport in (('native',source.notes),('web',source.web),('writer',source.writer)):
                report[name+'_stages']=[{k:r[k] for k in ('stage','status','error_code','api_code') if k in r} for r in transport.report['stages']]
            source.web.shards.clear();source.web.close()
        for value in (saved,credentials):
            if value:value.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
