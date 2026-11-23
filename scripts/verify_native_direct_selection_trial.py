#!/usr/bin/env python3
"""Supervise one native direct-chapter thought trial; dry run by default.

All source and credentials stay in memory or temporary RAM-backed profiles.
The apply mode requires the fingerprint from the preceding prepared dry run.
"""
import argparse
import json
import resource
import traceback

from native_direct_selection_preflight import bind_native_source
from native_direct_selection_trial_broker import execute
from secure_native_session import NativeSessionStore
from secure_native_thought_trial import NativeThoughtTrialStore
from secure_selection_trial import SelectionTrialStore
from secure_weread_session import SessionStore
from selection_trial_model import fingerprint
from selection_trial_probe import SelectionProbe,prepare_web_handoff
from verify_native_chapter_package import ChapterProbe
from verify_native_thought_trial import other_pending
from verify_translation_preflight import save_refreshed_web_session


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply',action='store_true');parser.add_argument('--expected-intent')
    parser.add_argument('--offline-draft',action='store_true',help='Create the thought draft offline before reconnecting')
    parser.add_argument('--book-offset',type=int,choices=range(51),default=15)
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    if not args.lua_command or args.apply!=bool(args.expected_intent):parser.error('runner and apply fingerprint required')
    report={'result':'UNVERIFIED','authentication_posts':0,'account_data_posts':0};phase='intent';saved=credentials=probe=None
    store=SelectionTrialStore()
    try:
        resource.setrlimit(resource.RLIMIT_CORE,(0,0))
        if other_pending() or NativeThoughtTrialStore().pending():raise ValueError('direct_selection_trial/other_pending')
        state,receipt=store.read()
        if args.apply and (state is None or state['phase']!='prepared' or fingerprint(state['plan'])!=args.expected_intent):
            raise ValueError('direct_selection_trial/intent')
        if not args.apply and state is not None:raise ValueError('direct_selection_trial/intent')
        phase='session';session=SessionStore();saved=session.load();credentials=NativeSessionStore().load(saved['vid'])
        probe=SelectionProbe()
        if state is None:
            phase='sample';sample,_,_=ChapterProbe().inspect(credentials,args.book_offset)
            probe.web.requested_book=sample['book_id']
        phase='selection';probe.prepare(saved,credentials,state['plan'] if state else None)
        phase='source';source=bind_native_source(probe,credentials)
        saved=prepare_web_handoff(session,saved,probe)
        if state is None:
            phase='prepare_intent';receipt=store.prepare(probe.plan.bound)
        def persist_final():save_refreshed_web_session(session,saved,probe.web)
        phase='reader';execute(probe,credentials,store,receipt,args.lua_command,source=source,armed=args.apply,report=report,on_final=persist_final,
            offline_draft=args.offline_draft)
        report['authentication_posts']=0
    except (Exception,KeyboardInterrupt) as error:
        report.update(result='UNVERIFIED',phase=phase,no_automatic_replay=True)
        allowed={'selection_trial/changed','selection_trial/owner','selection_trial/book_missing','selection_trial/metadata',
            'selection_trial/existing_nonce','selection_trial/consumed','selection_scope','selection_input',
            'reading_baseline_changed','reading_no_text_sample','direct_selection_preflight/chapter','direct_selection_preflight/source'}
        if str(error) in allowed:report['reason']=str(error)
        if 'HTTP 401' in str(error):report['reason']='auth_expired'
        elif 'HTTP 429' in str(error):report['reason']='rate_limited'
        if probe and probe.notes.report['stages']:
            last=probe.notes.report['stages'][-1]
            if last.get('stage') in {'selection_trial_baseline','selection_trial_metadata','selection_trial_independent'} and type(last.get('status')) is int:
                report['last_native_status']=last['status']
        if type(error).__name__ in {'ValueError','PreflightError','ProbeError','StoreError','KeyError','TypeError'}:
            report['error_type']=type(error).__name__
        frames=traceback.extract_tb(error.__traceback__)
        if frames and frames[-1].filename.endswith(('selection_trial_probe.py','verify_owner_reading.py','verify_web_source_progress.py',
                'verify_eink_login.py','verify_annotation_experiment.py','selection_trial_model.py')):
            report['error_location']=frames[-1].name+':'+str(frames[-1].lineno)
        try:
            state,_=store.read();report.update(intent_state=state['phase'] if state else 'absent',
                independent_steps=state['native_steps'] if state else report.get('independent_steps',0))
        except Exception:report['intent_state']='unverified'
    finally:
        if probe:
            probe.web.shards.clear();probe.web.close()
        if saved:saved.clear()
        if credentials:credentials.clear()
    print(json.dumps(report));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
