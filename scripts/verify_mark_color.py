#!/usr/bin/env python3
"""Prototype the official color palette, on fresh test highlights only.

Offline by default; --saved-session reads only. --apply reserves a fixed
16-dispatch plan, never replays a claimed step, and independently reads every
result. One newly created mark at most may exist at any time. The owner's
continuing development authorization is required. No private data is printed.
"""
import argparse
import json
from annotation_experiment_model import digest
from highlight_trial_model import observe,PendingObservation,bind as highlight_bind,request as highlight_request
from mark_color_model import STEPS,bind,create_body,color_body
from secure_mark_color import MarkColorStore
from secure_native_session import NativeSessionStore
from secure_native_thought_trial import NativeThoughtTrialStore
from secure_selection_trial import SelectionTrialStore
from secure_weread_session import SessionStore
from selection_trial_probe import SelectionProbe
from verify_annotation_experiment import AnnotationProbe
from verify_eink_login import BASE,ProbeError
from verify_highlight_trial import HighlightProbe
from verify_native_thought_trial import other_pending
from verify_owner_reading import reading_position
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE as WEB


class ColorProbe:
    def __init__(self,highlight=None,store=None):
        # Full preparation + zero-write rehearsal + sixteen guarded steps:
        # 21 initial GETs + 16 * (4 before + up to 12 readback) = 277.
        self.highlight=highlight or HighlightProbe(SelectionProbe(notes=AnnotationProbe(max_gets=280)))
        self.store=store or MarkColorStore()
        self.bound=None;self.receipt=None;self.target=None;self.row=None;self.posts=0
        self.resume_step=None

    def prepare(self,saved,credentials):
        if self.bound is not None or self.store.read()[0] is not None:raise ValueError('mark_color/pending')
        value=self.highlight.prepare(saved,credentials);self.bound=bind(value,self.highlight.source.plan.context);return self.bound

    def resume(self,saved,credentials):
        """Only a never-claimed create step after a verified deletion may run.

        Reconstruct the exact source, catalog, full original state and Web
        position with the stored nonce. A claimed/unknown dispatch cannot be
        restarted, and an existing target cannot enter this path.
        """
        if self.bound is not None:raise ValueError('mark_color/consumed')
        value,receipt=self.store.read()
        if (value is None or value['phase']!='pending' or value['step'] not in (8,10,12,14)
                or value['target'] is not None or value['dispatch_sha256'] is not None):raise ValueError('mark_color/not_unclaimed')
        p=self.highlight;source=p.source
        source.prepare(saved,credentials,existing=value['plan']['highlight']['selection'])
        p.body=highlight_request(source.plan.context);p.bound=highlight_bind(source.plan.bound,p.body)
        bound=bind(p.bound,source.plan.context)
        if bound!=value['plan']:raise ValueError('mark_color/changed')
        self.bound=bound;self.receipt=receipt;self.posts=value['step'];self.resume_step=value['step'];self.current()
        return bound

    def current(self):
        self.highlight.current()
        if self.bound!=bind(self.highlight.bound,self.highlight.source.plan.context):raise ValueError('mark_color/changed')

    def before(self,credentials):
        self.current();p=self.highlight;value=p.source.notes.observe(credentials,'mark_color_before_step')
        observe(p.source.plan.baseline,value,dict(p.body,colorStyle=self.row['colorStyle']) if self.row else p.body,
            target=self.target,deleted=self.target is None)

    def post(self,credentials,index):
        self.current();p=self.highlight;v,receipt=self.store.read()
        if (type(index) is not int or not 0<=index<len(STEPS) or v is None or receipt!=self.receipt or v['plan']!=self.bound or v['step']!=index or v['target']!=self.target
                or self.posts!=index or self.target and self.target['id'] in p.source.plan.baseline['marks']['updated']):raise ValueError('mark_color/dispatch')
        operation,color=STEPS[index]
        if operation=='create':path='/book/addBookmark';body=create_body(p.source.plan.context,color=color)
        elif operation=='color':path='/book/updateBookmark';body=color_body(self.row,color)
        else:path='/book/removeBookmark';body=dict(bookmarkIds=[self.target['id']])
        self.receipt=self.store.claim(self.receipt,digest(body));self.posts+=1
        try:p.source.writer.request('mark_color_step_'+str(index),BASE+path,body,credentials)
        except ProbeError:pass

    def read(self,credentials,index):
        self.current();p=self.highlight;operation,color=STEPS[index]
        for attempt in range(3):
            if attempt:p.sleep(.5*attempt)
            value=p.source.notes.observe(credentials,'mark_color_readback_'+str(index))
            try:
                if operation=='color':
                    from mark_color_model import observe_color
                    target,row=observe_color(p.source.plan.baseline,value,p.body,self.target,self.row,color)
                else:
                    body=dict(p.body,colorStyle=self.row['colorStyle'] if operation=='delete' else color)
                    target=observe(p.source.plan.baseline,value,body,target=self.target,deleted=operation=='delete')
                    row=None if target is None else value['marks']['updated'][target['id']]
            except PendingObservation:
                if attempt==2:raise
                continue
            return target,row,value
        raise ValueError('mark_color/readback')

    def _final(self,credentials,final,*,apply,start=0):
        p=self.highlight
        p.source.web.verify_account()
        after=reading_position(p.source.web.request('progress_after',WEB+'/web/book/getProgress?bookId='+p.source.plan.bound['book_id']),p.source.plan.bound['book_id'])
        if after!=p.source.plan.web_position:raise ValueError('mark_color/web_position')
        if apply:self.store.finish(self.receipt)
        if self.store.read()[0] is not None:raise ValueError('mark_color/cleanup')
        completed=STEPS[start:self.posts] if apply else ()
        return dict(result='PASS',mode='continuation' if start else 'apply' if apply else 'read-only',account_data_posts=self.posts-start,
            authentication_posts=0,prior_dispatch_slots=start,independent_steps=len(completed),
            initial_colors_verified=sorted({color for op,color in completed if op=='create'}),
            modified_colors_verified=sorted({color for op,color in completed if op=='color'}),original_records_and_positions_restored=True,
            style_and_source_preserved=True,derived_chapter_metadata_changed=final['marks']['chapters']!=p.source.plan.baseline['marks']['chapters'],
            intent_state='absent',no_automatic_replay=True)

    def run(self,credentials,*,apply=False):
        if self.resume_step is not None:raise ValueError('mark_color/not_fresh')
        self.current();p=self.highlight;p.source.baseline(credentials,'mark_color_before')
        if apply:
            self.receipt=self.store.reserve(self.bound)
            for index,_step in enumerate(STEPS):
                self.before(credentials);self.post(credentials,index)
                self.target,self.row,final=self.read(credentials,index)
                self.receipt=self.store.advance(self.receipt,self.target)
        else:final=p.source.baseline(credentials,'mark_color_readonly')
        return self._final(credentials,final,apply=apply)

    def run_remaining(self,credentials):
        start=self.resume_step
        if start is None or self.posts!=start:raise ValueError('mark_color/not_unclaimed')
        self.current();p=self.highlight;p.source.baseline(credentials,'mark_color_continuation_before')
        value,receipt=self.store.read()
        if (receipt!=self.receipt or value['phase']!='pending' or value['step']!=start
                or value['target'] is not None):raise ValueError('mark_color/replaced')
        self.before(credentials)
        for index in range(start,len(STEPS)):
            self.before(credentials);self.post(credentials,index)
            self.target,self.row,final=self.read(credentials,index)
            self.receipt=self.store.advance(self.receipt,self.target)
        return self._final(credentials,final,apply=True,start=start)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    mode=parser.add_mutually_exclusive_group();mode.add_argument('--apply',action='store_true');mode.add_argument('--status',action='store_true')
    mode.add_argument('--continue-unclaimed',action='store_true');args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',account_data_posts=0);probe=saved=credentials=None;phase='init'
    try:
        if args.saved_session:
            store=MarkColorStore()
            if args.status:
                value,_receipt=store.read();report.update(result='PASS',intent_state=value['phase'] if value else 'absent')
            else:
                if other_pending(exclude_mark_color=args.continue_unclaimed) or NativeThoughtTrialStore().pending() or SelectionTrialStore().pending():raise ValueError('mark_color/other_pending')
                phase='load_session';session=SessionStore();saved=session.load();credentials=NativeSessionStore().load(saved['vid'])
                probe=ColorProbe(store=store)
                if args.continue_unclaimed:
                    phase='resume';probe.resume(saved,credentials);phase='continue';report=probe.run_remaining(credentials)
                else:
                    phase='prepare';probe.prepare(saved,credentials)
                    phase='apply' if args.apply else 'read_only';report=probe.run(credentials,apply=args.apply)
                phase='save_web_session';save_refreshed_web_session(session,saved,probe.highlight.source.web)
        elif args.apply or args.status or args.continue_unclaimed:raise ValueError('mark_color/offline')
    except (Exception,KeyboardInterrupt):
        report=dict(result='UNVERIFIED',phase=phase,account_data_posts=probe.posts-(probe.resume_step or 0) if probe else 0,no_automatic_replay=True)
        if args.saved_session:
            try:
                value,_receipt=MarkColorStore().read();report['intent_state']=value['phase'] if value else 'absent'
            except Exception:report['intent_state']='unverified'
    finally:
        report['authentication_posts']=0
        if probe:
            for name,transport in [('native',probe.highlight.source.notes),('web',probe.highlight.source.web),('writer',probe.highlight.source.writer)]:
                report[name+'_stages']=[{k:v[k] for k in ('stage','status','error_code','api_code') if k in v} for v in transport.report['stages']]
            probe.highlight.source.web.shards.clear();probe.highlight.source.web.close()
        for value in (saved,credentials):
            if value:value.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
