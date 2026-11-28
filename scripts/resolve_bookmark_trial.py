#!/usr/bin/env python3
"""Read-only pending bookmark reconstruction, optional one remaining deletion.

Default offline. Saved-session needs an exact intent digest. Inspection cannot
advance or dispatch; resume-delete only uses the original unused deletion slot,
never repeats creation, and refuses any changed source/position/original set.
"""
import argparse
import json
from bookmark_trial_recovery import rebuild,resume_delete,reconcile_deleted,finish_reconcile
from secure_bookmark_trial import BookmarkTrialStore
from secure_native_session import NativeSessionStore
from secure_native_thought_trial import NativeThoughtTrialStore
from secure_selection_trial import SelectionTrialStore
from secure_weread_session import SessionStore
from verify_native_thought_trial import other_pending
from verify_translation_preflight import save_refreshed_web_session


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    mode=parser.add_mutually_exclusive_group();mode.add_argument('--resume-delete',action='store_true');mode.add_argument('--reconcile-deleted',action='store_true')
    parser.add_argument('--expected-intent');args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0);probe=saved=credentials=None;phase='init'
    try:
        if args.saved_session:
            if other_pending(exclude_bookmark=True) or NativeThoughtTrialStore().pending() or SelectionTrialStore().pending():raise ValueError('bookmark_recovery/other_pending')
            phase='load_session';session=SessionStore();saved=session.load();credentials=NativeSessionStore().load(saved['vid'])
            phase='read_only'
            if args.reconcile_deleted:
                probe=reconcile_deleted(saved,credentials,BookmarkTrialStore(),args.expected_intent)
                report=finish_reconcile(probe,credentials,on_final=lambda:save_refreshed_web_session(session,saved,probe.source.web))
            else:probe,report=rebuild(saved,credentials,BookmarkTrialStore(),args.expected_intent)
            if args.resume_delete:
                phase='remaining_delete';report=resume_delete(probe,credentials,
                    on_final=lambda:save_refreshed_web_session(session,saved,probe.source.web))
            elif not args.reconcile_deleted:save_refreshed_web_session(session,saved,probe.source.web)
        elif args.resume_delete or args.reconcile_deleted or args.expected_intent:raise ValueError('bookmark_recovery/offline')
    except (Exception,KeyboardInterrupt):
        report=dict(result='UNVERIFIED',phase=phase,account_data_posts=max(0,probe.posts-(2 if args.reconcile_deleted else 1)) if probe else 0,no_create_replay=True)
        if args.saved_session:
            try:
                value,_receipt=BookmarkTrialStore().read();report['intent_state']=value['phase'] if value else 'absent'
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
