#!/usr/bin/env python3
"""New test highlight -> straight -> wave -> delete, max four data dispatches.

Default offline; --saved-session reads only. --apply requires the continuing
owner development grant. No pre-existing highlight is modified. Durable phase
claims forbid replay; full independent reads confirm each step. No credentials,
IDs, quotations or private source files appear in output.

Endpoint reference: weread-omni 88bd2e095d7d7ee423eaadf8f40653e72c5be6d4
src/api/resources/notes.ts (MIT). Style enum independently checked against the
official public reader 9.625560b7.js: straight=0, marker=1, wave=2.
"""
import argparse
import json
from mark_style_trial_model import bind,style_body,observe_change
from highlight_trial_model import observe,PendingObservation
from secure_mark_style_trial import MarkStyleTrialStore
from secure_weread_session import SessionStore
from secure_native_session import NativeSessionStore
from secure_native_thought_trial import NativeThoughtTrialStore
from secure_selection_trial import SelectionTrialStore
from verify_highlight_trial import HighlightProbe
from verify_native_thought_trial import other_pending
from verify_eink_login import BASE,ProbeError
from verify_owner_reading import reading_position
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE as WEB


class StyleProbe:
    def __init__(self,highlight=None,store=None):
        self.highlight=highlight or HighlightProbe();self.store=store or MarkStyleTrialStore()
        self.bound=None;self.receipt=None;self.posts=0;self.target=None;self.row=None;self.sent=set()

    def prepare(self,saved,credentials):
        if self.bound is not None or self.store.read()[0] is not None:raise ValueError('mark_style/pending')
        self.bound=bind(self.highlight.prepare(saved,credentials));return self.bound

    def current(self):
        self.highlight.current()
        if self.bound!=bind(self.highlight.bound):raise ValueError('mark_style/changed')

    def post(self,credentials,phase,path,body):
        self.current();p=self.highlight
        specifications={
            'create_pending':(0,'/book/addBookmark',p.body),
            'straight_pending':(1,'/book/updateBookmark',style_body(self.row,0) if self.row else None),
            'wave_pending':(2,'/book/updateBookmark',style_body(self.row,2) if self.row else None),
            'delete_pending':(3,'/book/removeBookmark',dict(bookmarkIds=[self.target['id']]) if self.target else None),
        }
        count,wanted_path,wanted=specifications.get(phase,(None,None,None))
        state,receipt=self.store.read()
        if (self.posts!=count or (path,body)!=(wanted_path,wanted) or phase in self.sent
                or receipt!=self.receipt or state is None or state['plan']!=self.bound
                or state['target']!=self.target or not self.store.owns(self.receipt,phase)
                or self.target and self.target['id'] in p.source.plan.baseline['marks']['updated']):raise ValueError('mark_style/dispatch')
        self.posts+=1;self.sent.add(phase)
        try:p.source.writer.request('mark_style_'+phase,BASE+path,body,credentials)
        except ProbeError:pass

    def read(self,credentials,style=None,deleted=False):
        self.current();p=self.highlight
        for attempt in range(3):
            if attempt:p.sleep(.5*attempt)
            value=p.source.notes.observe(credentials,'mark_style_readback')
            try:
                if style is None:
                    target=observe(p.source.plan.baseline,value,dict(p.body,style=self.row['style']) if deleted else p.body,
                        deleted=deleted,target=self.target)
                    row=None if deleted else value['marks']['updated'][target['id']]
                else:target,row=observe_change(p.source.plan.baseline,value,p.body,self.target,self.row,style)
            except PendingObservation:
                if attempt==2:raise
                continue
            return target,row,value
        raise ValueError('mark_style/readback')

    def run(self,credentials,*,apply=False):
        self.current();p=self.highlight;p.source.baseline(credentials,'mark_style_before')
        if apply:
            self.receipt=self.store.reserve(self.bound)
            self.post(credentials,'create_pending','/book/addBookmark',p.body)
            self.target,self.row,_value=self.read(credentials)
            self.receipt=self.store.advance(self.receipt,'created',target=self.target)
            for style,pending,verified in [(0,'straight_pending','straight'),(2,'wave_pending','wave')]:
                self.read(credentials,self.row['style'])
                self.receipt=self.store.advance(self.receipt,pending)
                self.post(credentials,pending,'/book/updateBookmark',style_body(self.row,style))
                self.target,self.row,_value=self.read(credentials,style)
                self.receipt=self.store.advance(self.receipt,verified,target=self.target)
            self.read(credentials,self.row['style'])
            self.receipt=self.store.advance(self.receipt,'delete_pending')
            self.post(credentials,'delete_pending','/book/removeBookmark',dict(bookmarkIds=[self.target['id']]))
            _target,_row,final=self.read(credentials,deleted=True)
        else:final=p.source.baseline(credentials,'mark_style_readonly')
        p.source.web.verify_account()
        after=reading_position(p.source.web.request('progress_after',WEB+'/web/book/getProgress?bookId='+p.source.plan.bound['book_id']),p.source.plan.bound['book_id'])
        if after!=p.source.plan.web_position:raise ValueError('mark_style/web_position')
        if apply:
            self.receipt=self.store.advance(self.receipt,'verified');self.store.finish(self.receipt)
            if self.store.read()[0] is not None:raise ValueError('mark_style/cleanup')
        return dict(result='PASS',mode='apply' if apply else 'read-only',account_data_posts=self.posts,
            independent_steps=4 if apply else 0,style_values_verified=[1,0,2] if apply else [],
            color_preserved=True,original_records_restored=True,web_position_unchanged=True,
            derived_chapter_metadata_changed=final['marks']['chapters']!=p.source.plan.baseline['marks']['chapters'],
            intent_state='absent',no_automatic_replay=True)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    group=parser.add_mutually_exclusive_group();group.add_argument('--apply',action='store_true');group.add_argument('--status',action='store_true');args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0);probe=saved=credentials=None;phase='init'
    try:
        if args.saved_session:
            store=MarkStyleTrialStore()
            if args.status:
                value,_receipt=store.read();report.update(result='PASS',intent_state=value['phase'] if value else 'absent')
            else:
                if other_pending() or NativeThoughtTrialStore().pending() or SelectionTrialStore().pending():raise ValueError('mark_style/other_pending')
                phase='load_session';session=SessionStore();saved=session.load();credentials=NativeSessionStore().load(saved['vid'])
                probe=StyleProbe(store=store);phase='prepare';probe.prepare(saved,credentials)
                phase='apply' if args.apply else 'read_only';report=probe.run(credentials,apply=args.apply)
                save_refreshed_web_session(session,saved,probe.highlight.source.web)
        elif args.apply or args.status:raise ValueError('mark_style/offline')
    except (Exception,KeyboardInterrupt):
        report=dict(result='UNVERIFIED',phase=phase,account_data_posts=probe.posts if probe else 0,no_automatic_replay=True)
        if args.saved_session:
            try:
                value,_receipt=MarkStyleTrialStore().read();report['intent_state']=value['phase'] if value else 'absent'
            except Exception:report['intent_state']='unverified'
    finally:
        report['authentication_posts']=0
        if probe:
            source=probe.highlight.source
            for name,transport in [('native',source.notes),('web',source.web),('writer',source.writer)]:
                report[name+'_stages']=[{k:v[k] for k in ('stage','status','error_code','api_code') if k in v} for v in transport.report['stages']]
            source.web.shards.clear();source.web.close()
        for value in (saved,credentials):
            if value:value.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
