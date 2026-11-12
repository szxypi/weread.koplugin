#!/usr/bin/env python3
"""Validate one initial style by creating/removing only a fresh test highlight.

Offline by default; --saved-session is read-only. --apply reserves exactly two
dispatches, with independent full readbacks and no pending replay. Requires
the owner's continuing development grant. Original annotations are protected.
"""
import argparse
import json
from initial_mark_style_model import bind,create_body
from secure_initial_mark_style import InitialMarkStyleStore
from secure_native_session import NativeSessionStore
from secure_native_thought_trial import NativeThoughtTrialStore
from secure_selection_trial import SelectionTrialStore
from secure_weread_session import SessionStore
from verify_highlight_trial import HighlightProbe
from verify_native_thought_trial import other_pending
from verify_translation_preflight import save_refreshed_web_session


class InitialStyleProbe(HighlightProbe):
    def __init__(self,style,source=None,store=None,**options):
        if type(style) is not int or style not in (0,1,2):raise ValueError('initial_style/value')
        self.style=style
        super().__init__(source,store or InitialMarkStyleStore(),**options)

    def prepare(self,saved,credentials):
        super().prepare(saved,credentials)
        self.body=create_body(self.source.plan.context,self.style)
        self.bound=bind(self.source.plan.bound,self.source.plan.context,self.style);return self.bound

    def current(self):
        self.source.current()
        if (self.body!=create_body(self.source.plan.context,self.style)
                or self.bound!=bind(self.source.plan.bound,self.source.plan.context,self.style)):
            raise ValueError('initial_style/changed')


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--style',type=int,choices=(0,1,2));group=parser.add_mutually_exclusive_group()
    group.add_argument('--apply',action='store_true');group.add_argument('--status',action='store_true');args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',account_data_posts=0);probe=saved=credentials=None;phase='init'
    try:
        if args.saved_session:
            store=InitialMarkStyleStore()
            if args.status:
                value,_receipt=store.read();report.update(result='PASS',intent_state=value['phase'] if value else 'absent')
            else:
                if args.style is None or other_pending() or NativeThoughtTrialStore().pending() or SelectionTrialStore().pending():
                    raise ValueError('initial_style/not_ready')
                phase='load_session';session=SessionStore();saved=session.load();credentials=NativeSessionStore().load(saved['vid'])
                probe=InitialStyleProbe(args.style,store=store);phase='prepare';probe.prepare(saved,credentials)
                phase='apply' if args.apply else 'read_only';report=probe.run(credentials,apply=args.apply)
                report['initial_style']=args.style
                phase='save_web_session';save_refreshed_web_session(session,saved,probe.source.web)
        elif args.apply or args.status:raise ValueError('initial_style/offline')
    except (Exception,KeyboardInterrupt):
        report=dict(result='UNVERIFIED',phase=phase,account_data_posts=probe.posts if probe else 0,no_automatic_replay=True)
        if args.saved_session:
            try:
                value,_receipt=InitialMarkStyleStore().read();report['intent_state']=value['phase'] if value else 'absent'
            except Exception:report['intent_state']='unverified'
    finally:
        report['authentication_posts']=0
        if probe:
            for name,transport in [('native',probe.source.notes),('web',probe.source.web),('writer',probe.source.writer)]:
                report[name+'_stages']=[{k:v[k] for k in ('stage','status','error_code','api_code') if k in v} for v in transport.report['stages']]
            probe.source.web.shards.clear();probe.source.web.close()
        for value in (saved,credentials):
            if value:value.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
