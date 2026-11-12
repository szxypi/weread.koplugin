#!/usr/bin/env python3
"""Source point bookmark creation/removal; offline unless explicitly opted in.

Saved-session alone reads only. Apply reserves two slots before any dispatch,
modifies only one new test record, independently reads each step and never
replays an unknown mutation. Continuing owner development authorization applies.
Private source, records and credentials are not printed or saved to files.
"""
import argparse
import hashlib
import json
from bookmark_point import point_range,from_mark
from bookmark_trial_model import bind,request,observe
from highlight_trial_model import PendingObservation
from secure_bookmark_trial import BookmarkTrialStore
from secure_native_session import NativeSessionStore
from secure_native_thought_trial import NativeThoughtTrialStore
from secure_selection_trial import SelectionTrialStore
from secure_weread_session import SessionStore
from selection_trial_probe import SelectionProbe
from fetch_weread_epub import decode_content_shards
from verify_eink_login import BASE,ProbeError
from verify_native_thought_trial import other_pending
from verify_owner_reading import reading_position
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE as WEB


class BookmarkProbe:
    def __init__(self,source=None,store=None):
        self.source=source or SelectionProbe();self.store=store or BookmarkTrialStore()
        self.raw=None;self.first=None;self.bound=None;self.body=None;self.receipt=None;self.target=None;self.posts=0

    def prepare(self,saved,credentials):
        if self.store.native or self.bound is not None or self.store.read()[0] is not None:raise ValueError('bookmark_trial/pending')
        p=self.source.prepare(saved,credentials)
        self.raw=decode_content_shards(*(self.source.web.shards[k] for k in ('e_0','e_1','e_3')))
        self.first=self.source.payload['selection_preview']['first'];self.body=request(p.context,self.raw,self.first)
        for row in p.baseline['marks']['updated'].values():
            if row.get('type')==0 and row.get('chapterUid')==self.body['chapterUid'] and point_range(row.get('range'))==point_range(self.body['range']):raise ValueError('bookmark_trial/existing')
        self.bound=bind(p.bound,self.body);return self.bound

    def current(self):
        self.source.current()
        if (hashlib.sha256(self.raw.encode()).hexdigest()!=self.source.payload['source_raw_sha256']
                or self.body!=request(self.source.plan.context,self.raw,self.first) or self.bound!=bind(self.source.plan.bound,self.body,native=self.store.native)):
            raise ValueError('bookmark_trial/changed')

    def read(self,credentials,*,deleted=False):
        self.current()
        for attempt in range(3):
            if attempt:self.source.sleep(.5*attempt)
            value=self.source.notes.observe(credentials,'bookmark_trial_readback')
            try:target=observe(self.source.plan.baseline,value,self.body,deleted=deleted,target=self.target)
            except PendingObservation:
                if attempt==2:raise
                continue
            if target:
                from_mark(self.raw,self.body['bookId'],str(self.body['chapterUid']),value['marks']['updated'][target['id']])
            return target,value
        raise ValueError('bookmark_trial/readback')

    def post(self,credentials,phase,path,body):
        if self.store.native:raise ValueError('bookmark_trial/native_readonly')
        self.current();state,receipt=self.store.read()
        expected=('/book/addBookmark',self.body) if phase=='create_pending' else ('/book/removeBookmark',dict(bookmarkIds=[self.target['id']])) if self.target else None
        if (phase not in ('create_pending','delete_pending') or self.posts!=int(phase=='delete_pending') or receipt!=self.receipt
                or state is None or state['plan']!=self.bound or state['target']!=self.target or not self.store.owns(self.receipt,phase)
                or (path,body)!=expected or self.target and self.target['id'] in self.source.plan.baseline['marks']['updated']):raise ValueError('bookmark_trial/dispatch')
        self.posts+=1
        try:self.source.writer.request('bookmark_trial_'+phase,BASE+path,body,credentials)
        except ProbeError:pass

    def run(self,credentials,*,apply=False):
        if self.store.native:raise ValueError('bookmark_trial/native_readonly')
        self.current();self.source.baseline(credentials,'bookmark_trial_before');p=self.source.plan
        text_returned=None;position_roundtrip=False
        if apply:
            self.receipt=self.store.reserve(self.bound)
            self.post(credentials,'create_pending','/book/addBookmark',self.body)
            self.target,created=self.read(credentials)
            row=created['marks']['updated'][self.target['id']];text_returned=bool(row.get('markText'))
            point=from_mark(self.raw,self.body['bookId'],str(self.body['chapterUid']),row)
            if point['chapter_offset']!=self.first:raise ValueError('bookmark_trial/position')
            position_roundtrip=True
            self.receipt=self.store.advance(self.receipt,'created',target=self.target)
            self.read(credentials);self.receipt=self.store.advance(self.receipt,'delete_pending')
            self.post(credentials,'delete_pending','/book/removeBookmark',dict(bookmarkIds=[self.target['id']]))
            _target,final=self.read(credentials,deleted=True)
        else:final=self.source.baseline(credentials,'bookmark_trial_readonly')
        self.source.web.verify_account()
        after=reading_position(self.source.web.request('progress_after',WEB+'/web/book/getProgress?bookId='+p.bound['book_id']),p.bound['book_id'])
        if after!=p.web_position:raise ValueError('bookmark_trial/web_position')
        if apply:
            self.receipt=self.store.advance(self.receipt,'verified');self.store.finish(self.receipt)
            if self.store.read()!=(None,None):raise ValueError('bookmark_trial/cleanup')
        return dict(result='PASS',mode='apply' if apply else 'read-only',account_data_posts=self.posts,authentication_posts=0,
            independent_steps=2 if apply else 0,range_is_point=True,bookmark_text_returned=text_returned,
            source_position_roundtrip=position_roundtrip,original_records_restored=True,web_position_unchanged=True,
            derived_chapter_metadata_changed=final['marks']['chapters']!=p.baseline['marks']['chapters'],intent_state='absent',no_automatic_replay=True)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    group=parser.add_mutually_exclusive_group();group.add_argument('--apply',action='store_true');group.add_argument('--status',action='store_true');args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0);probe=saved=credentials=None;phase='init'
    try:
        if args.saved_session:
            store=BookmarkTrialStore()
            if args.status:
                value,_receipt=store.read();report.update(result='PASS',intent_state=value['phase'] if value else 'absent')
            else:
                if other_pending() or NativeThoughtTrialStore().pending() or SelectionTrialStore().pending():raise ValueError('bookmark_trial/other_pending')
                phase='load_session';session=SessionStore();saved=session.load();credentials=NativeSessionStore().load(saved['vid'])
                probe=BookmarkProbe(store=store);phase='prepare';probe.prepare(saved,credentials)
                phase='apply' if args.apply else 'read_only';report=probe.run(credentials,apply=args.apply)
                save_refreshed_web_session(session,saved,probe.source.web)
        elif args.apply or args.status:raise ValueError('bookmark_trial/offline')
    except (Exception,KeyboardInterrupt):
        report=dict(result='UNVERIFIED',phase=phase,account_data_posts=probe.posts if probe else 0,authentication_posts=0,no_automatic_replay=True)
        if args.saved_session:
            try:
                value,_receipt=BookmarkTrialStore().read();report['intent_state']=value['phase'] if value else 'absent'
            except Exception:report['intent_state']='unverified'
    finally:
        if probe:
            for name,transport in [('native',probe.source.notes),('web',probe.source.web),('writer',probe.source.writer)]:
                report[name+'_stages']=[{k:v[k] for k in ('stage','status','error_code','api_code') if k in v} for v in transport.report['stages']]
            probe.source.web.shards.clear();probe.source.web.close()
        for value in (saved,credentials):
            if value:value.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
