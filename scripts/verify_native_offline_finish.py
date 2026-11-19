#!/usr/bin/env python3
"""One bounded offline-finish round trip, with same-plan dry run and independent reads."""
import argparse
import json
from secure_native_finish_trial import NativeFinishTrialStore
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from secure_native_thought_trial import NativeThoughtTrialStore
from secure_selection_trial import SelectionTrialStore
from verify_native_finish_trial import FinishTrialProbe, TrialFailure, run
from verify_native_thought_trial import other_pending


def execute(probe, credentials, store, command, current, runner=run):
    if (not command or '--offline-queue' not in command or any(
            item==flag or item.startswith(flag+'=') for item in command for flag in ('--armed','--mock-port'))):
        raise ValueError('offline_finish/command')
    dry=runner(probe,credentials,store,command,armed=False,current=current,offline=True)
    if dry.get('result')!='PASS' or dry.get('account_data_posts')!=0 or store.pending():
        raise ValueError('offline_finish/dry_run')
    current();probe.read(credentials,False)
    applied=runner(probe,credentials,store,command+['--armed'],armed=True,current=current,offline=True)
    if (applied.get('result')!='PASS' or applied.get('account_data_posts')!=2
            or applied.get('independent_steps')!=2 or store.pending()):
        raise ValueError('offline_finish/apply')
    return dry,applied


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--native-ui-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    report={'result':'OFFLINE_ONLY','account_data_posts':0,'authentication_posts':0}
    credentials=probe=None;phase='init';store=None
    try:
        if args.saved_session:
            if not args.native_ui_command:raise ValueError('offline_finish/command')
            store=NativeFinishTrialStore()
            if (store.pending() or other_pending(exclude_native_finish=True)
                    or NativeThoughtTrialStore().pending() or SelectionTrialStore().pending()):
                raise ValueError('offline_finish/pending')
            phase='load_session';owner=SessionStore().load()['vid'];credentials=NativeSessionStore().load(owner)
            def current():
                if NativeSessionStore().load(owner)!=credentials:raise ValueError('offline_finish/grant_replaced')
            phase='prepare';probe=FinishTrialProbe();probe.prepare(credentials)
            phase='execute';dry,applied=execute(probe,credentials,store,args.native_ui_command,current)
            report={'result':'PASS','dry_run':dry,'actual':applied,
                    'same_plan':True,'original_flags_groups_and_exact_position_restored':True,
                    'account_data_posts':2,'authentication_posts':0,'intent_state':'absent'}
        elif args.native_ui_command:raise ValueError('offline_finish/session_required')
    except (Exception,KeyboardInterrupt) as error:
        report={'result':'UNVERIFIED','phase':phase,'account_data_posts':None if phase=='execute' else 0,
                'authentication_posts':0,'no_automatic_replay':True}
        if isinstance(error,TrialFailure):report.update(native_ui=error.runner,independent_steps=error.steps)
        try:report['intent_state']='pending' if store and store.pending() else 'absent'
        except Exception:report['intent_state']='unverified'
    finally:
        if credentials:credentials.clear()
        if probe:report['host_stages']=[{key:row[key] for key in ('stage','status') if key in row} for row in probe.report['stages']]
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
