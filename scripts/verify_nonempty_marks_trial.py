#!/usr/bin/env python3
"""Native create/color/style/delete with nonempty original notes; default offline."""
import argparse
import json
from highlight_trial_model import observe,PendingObservation
from mark_color_model import observe_color
from mark_style_trial_model import observe_change
from nonempty_marks_trial import bind
from secure_nonempty_marks_trial import NonemptyMarksStore
from secure_native_session import NativeSessionStore
from secure_native_thought_trial import NativeThoughtTrialStore
from secure_selection_trial import SelectionTrialStore
from secure_weread_session import SessionStore
from verify_annotation_experiment import AnnotationProbe
from verify_highlight_trial import HighlightProbe
from verify_native_highlight_trial import TrialFailure
from verify_native_mark_style_trial import run
from verify_native_thought_trial import other_pending
from verify_translation_preflight import save_refreshed_web_session
from selection_trial_probe import prepare_web_handoff


class NonemptyMarksProbe:
    def __init__(self,highlight=None,store=None,selector=None):
        self.highlight=highlight or HighlightProbe();self.store=store or NonemptyMarksStore()
        self.selector=selector if selector is not None else AnnotationProbe()
        self.bound=self.target=self.row=None

    def prepare(self,saved,credentials,*,select_existing=True):
        if self.bound is not None or self.store.read()[0] is not None:raise ValueError('nonempty_marks/pending')
        selected=None
        if select_existing:
            selected=self.selector.prepare(credentials)
            if not selected.baseline['thoughts'] or not selected.baseline['marks']['updated']:raise ValueError('nonempty_marks/selection')
            self.highlight.source.web.requested_book=selected.bound['book_id']
        high=self.highlight.prepare(saved,credentials);baseline=self.highlight.source.plan.baseline
        if selected is not None and selected.baseline!=baseline:raise ValueError('nonempty_marks/changed_selection')
        self.bound=bind(high,baseline);return self.bound

    def current(self):
        self.highlight.current()
        if self.bound!=bind(self.highlight.bound,self.highlight.source.plan.baseline):raise ValueError('nonempty_marks/changed')

    def read(self,credentials,*,color=None,style=None,deleted=False):
        self.current();p=self.highlight
        for attempt in range(3):
            if attempt:p.sleep(.5*attempt)
            value=p.source.notes.observe(credentials,'nonempty_marks_readback')
            try:
                if deleted:
                    body=dict(p.body,style=self.row['style'],colorStyle=self.row['colorStyle'])
                    target=observe(p.source.plan.baseline,value,body,deleted=True,target=self.target);row=None
                elif self.row is None:
                    target=observe(p.source.plan.baseline,value,p.body);row=value['marks']['updated'][target['id']]
                elif color is not None and color!=self.row['colorStyle']:
                    target,row=observe_color(p.source.plan.baseline,value,p.body,self.target,self.row,color)
                elif style is not None and style!=self.row['style']:
                    target,row=observe_change(p.source.plan.baseline,value,dict(p.body,colorStyle=self.row['colorStyle']),self.target,self.row,style)
                else:
                    body=dict(p.body,style=self.row['style'],colorStyle=self.row['colorStyle'])
                    target=observe(p.source.plan.baseline,value,body,target=self.target);row=value['marks']['updated'][target['id']]
            except PendingObservation:
                if attempt==2:raise
                continue
            return target,row,value
        raise ValueError('nonempty_marks/readback')


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    group=parser.add_mutually_exclusive_group();group.add_argument('--dry-run',action='store_true');group.add_argument('--apply',action='store_true');group.add_argument('--status',action='store_true')
    parser.add_argument('--native-ui-command',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0);probe=saved=credentials=None;phase='init'
    try:
        if args.saved_session:
            store=NonemptyMarksStore()
            if args.status:
                state,_receipt=store.read();report.update(result='PASS',intent_state=state['phase'] if state else 'absent')
            else:
                if other_pending() or NativeThoughtTrialStore().pending() or SelectionTrialStore().pending():raise ValueError('nonempty_marks/other_pending')
                phase='load_session';session=SessionStore();saved=session.load();credentials=NativeSessionStore().load(saved['vid'])
                probe=NonemptyMarksProbe(store=store);phase='prepare';probe.prepare(saved,credentials)
                phase='web_handoff';saved=prepare_web_handoff(session,saved,probe.highlight.source)
                if not args.native_ui_command or not (args.apply or args.dry_run):raise ValueError('nonempty_marks/command')
                phase='apply' if args.apply else 'dry_run'
                report=run(probe,credentials,args.native_ui_command,armed=args.apply,color_style=True,
                    on_final=lambda:save_refreshed_web_session(session,saved,probe.highlight.source.web))
        elif args.native_ui_command or args.apply or args.dry_run or args.status:raise ValueError('nonempty_marks/offline')
    except (Exception,KeyboardInterrupt) as error:
        report=dict(result='UNVERIFIED',phase=phase,account_data_posts=0 if phase in ('init','load_session','prepare','web_handoff') else None,
            authentication_posts=0,no_automatic_replay=True)
        if isinstance(error,TrialFailure):report['native_ui']=error.runner
        if args.saved_session:
            try:
                state,_receipt=NonemptyMarksStore().read();report['intent_state']=state['phase'] if state else 'absent'
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
