#!/usr/bin/env python3
"""Supervise a direct-chapter highlight dry run, optionally followed by a single round trip."""
import argparse
import json
import resource
import traceback

from native_direct_highlight_trial_broker import execute
from native_direct_selection_preflight import bind_native_source
from secure_highlight_trial import HighlightTrialStore
from secure_native_session import NativeSessionStore
from secure_native_thought_trial import NativeThoughtTrialStore
from secure_selection_trial import SelectionTrialStore
from secure_weread_session import SessionStore
from selection_trial_probe import prepare_web_handoff
from verify_highlight_trial import HighlightProbe
from verify_native_chapter_package import ChapterProbe
from verify_native_thought_trial import other_pending
from verify_translation_preflight import save_refreshed_web_session


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--apply',action='store_true');parser.add_argument('--book-offset',type=int,choices=range(51),default=15)
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    if bool(args.saved_session)!=bool(args.lua_command) or args.apply and not args.saved_session:parser.error('saved session and private runner required together')
    report={'result':'OFFLINE_ONLY','account_data_posts':0,'authentication_posts':0}
    if not args.saved_session:print(json.dumps(report));return 0
    saved=credentials=probe=None;phase='intent';store=HighlightTrialStore(native=True)
    try:
        resource.setrlimit(resource.RLIMIT_CORE,(0,0))
        if (other_pending() or NativeThoughtTrialStore().pending() or SelectionTrialStore().pending()
                or HighlightTrialStore().read()!=(None,None) or store.read()!=(None,None)):
            raise ValueError('direct_highlight_trial/other_pending')
        phase='session';session=SessionStore();saved=session.load();credentials=NativeSessionStore().load(saved['vid'])
        phase='sample';sample,_,_=ChapterProbe().inspect(credentials,args.book_offset)
        probe=HighlightProbe();probe.source.web.requested_book=sample['book_id']
        phase='selection';probe.prepare(saved,credentials)
        phase='source';source=bind_native_source(probe.source,credentials)
        saved=prepare_web_handoff(session,saved,probe.source)
        phase='dry_run';execute(probe,credentials,store,args.lua_command,source=source,armed=False,report=report,
            on_final=lambda:save_refreshed_web_session(session,saved,probe.source.web))
        if args.apply:
            # Rebind both sources and all account data after the blocked preview.
            phase='recheck';saved=prepare_web_handoff(session,saved,probe.source)
            fresh=bind_native_source(probe.source,credentials)
            if any(source[key]!=fresh[key] for key in ('book_id','uid','book_version','source_sha256')):
                raise ValueError('direct_highlight_trial/source')
            probe.source.baseline(credentials,'direct_highlight_after_preview')
            phase='apply';execute(probe,credentials,store,args.lua_command,source=fresh,armed=True,report=report,
                on_final=lambda:save_refreshed_web_session(session,saved,probe.source.web))
        report['authentication_posts']=0
    except (Exception,KeyboardInterrupt) as error:
        report.update(result='UNVERIFIED',phase=phase,no_automatic_replay=True,authentication_posts=0)
        if phase!='apply':report['account_data_posts']=0
        if 'HTTP 401' in str(error):report['reason']='auth_expired'
        elif 'HTTP 429' in str(error):report['reason']='rate_limited'
        elif str(error) in {'direct_highlight_trial/intent','direct_highlight_trial/source','direct_highlight_trial/target',
                'direct_selection_preflight/chapter','direct_selection_preflight/source','highlight_trial/existing_thought'}:report['reason']=str(error)
        if type(error).__name__ in {'ValueError','PreflightError','ProbeError','StoreError','KeyError','TypeError'}:report['error_type']=type(error).__name__
        frames=traceback.extract_tb(error.__traceback__)
        if frames and frames[-1].filename.endswith(('selection_trial_probe.py','verify_highlight_trial.py','verify_eink_login.py',
                'native_direct_highlight_trial_broker.py','native_direct_selection_preflight.py')):
            report['error_location']=frames[-1].name+':'+str(frames[-1].lineno)
        try:
            state,_=store.read();report.update(intent_state=state['phase'] if state else 'absent',reserved_posts=state['reserved_posts'] if state else 0)
        except Exception:report['intent_state']='unverified'
    finally:
        if probe:
            probe.source.web.shards.clear();probe.source.web.close()
        if saved:saved.clear()
        if credentials:credentials.clear()
    print(json.dumps(report));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
