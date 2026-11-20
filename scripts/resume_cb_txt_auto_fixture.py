#!/usr/bin/env python3
"""Resume only the previously imported TXT whose initial write was not claimed.

No upload or initial request is replayed. The original fixture, upload receipt,
zero-claim initial intent, account, source and current shelf must all match.
"""
import argparse
import json
import resource
import time

from personal_upload_trial import hash_value, projection
from secure_native_session import NativeSessionStore
from secure_shelf_experiment import canonical
from secure_weread_session import SessionStore
from verify_cb_fixture_highlight_trial import ScopedNative as NotesProbe
from verify_cb_initial_fixture_ui_trial import run, ui_command
from verify_cb_txt_auto_fixture_ui_trial import auto_trial, manual_command, stores
from verify_cb_txt_fixture import MARKER, check_plan
from verify_cb_txt_initial_fixture_ui_trial import plan, summary
from verify_personal_upload_trial import acknowledged, readback


def fixture_authorized(receipt_backend,journal,claimed,target,owner):
    state,current=journal.read()
    if not state or current!=claimed or state['phase']!='imported' or state['target']!=target or state['plan']['owner']!=owner:return False
    expected=canonical(dict(schema=1,owner=owner,attempt=state['attempt'],target=target,plan_sha256=hash_value(state['plan'])))
    return receipt_backend.load()==expected


def resume_upload(probe,journal,grant,grant_check,source,*,apply,cleanup_gate,receipt_backend,notes, sleep=time.sleep):
    report=dict(result='UNVERIFIED',phase='preflight',credential_requests=0,cos_put_attempts=0,notify_posts=0,
                cleanup_posts=0,authentication_posts=0,source_verified=False)
    try:
        state,claimed=journal.read();target=state['target'];owner=state['plan']['owner'];plan_value=state['plan']
        if not apply or grant_check(grant) is not True or not fixture_authorized(receipt_backend,journal,claimed,target,owner):
            raise ValueError('resume/scope')
        def check_shelf():
            shelf=probe.shelf(grant);check_plan(plan_value,grant,shelf,target,True)
            if any(str(item)==target for group in shelf.get('archive',[]) for item in group.get('bookIds',[])):
                raise ValueError('resume/grouped')
            return shelf
        first=check_shelf();second=check_shelf()
        if projection(first,target)!=projection(second,target) or notes(target) is not True:raise ValueError('resume/changed')
        report['source_verified']=source(target) is True
        if not report['source_verified'] or cleanup_gate(journal,claimed,plan_value,target) is not True:
            raise ValueError('resume/unfinished')
        if notes(target) is not True or not fixture_authorized(receipt_backend,journal,claimed,target,owner):raise ValueError('resume/changed')
        check_shelf()
        claimed=journal.advance(claimed,'cleanup_pending');report['phase']='cleanup_pending'
        try:ack=acknowledged(probe.cleanup(grant,claimed))
        except Exception:ack=False
        finally:report['cleanup_posts']=probe.attempts['cleanup']
        restored=readback(probe,grant,plan_value,target,False,3 if ack else 1,sleep)
        report.update(cleanup_acknowledged=ack,restore_observed=restored)
        if not ack or not restored:raise ValueError('resume/cleanup_unconfirmed')
        check_plan(plan_value,grant,probe.shelf(grant),target,False)
        if grant_check(grant) is not True:raise ValueError('resume/stale')
        journal.advance(claimed,'restored');report.update(result='TXT_IMPORT_AND_SOURCE_VERIFIED',phase='restored')
    except Exception:
        report['reason']='resume_unverified'
    return report


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');parser.add_argument('--resume',action='store_true')
    args=parser.parse_args(argv)
    if args.saved_session!=args.resume:parser.error('both options are required')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY',account_data_writes_known=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=None
    try:
        first_command,second_command=ui_command(),manual_command();session=SessionStore();saved=session.load()
        owner=saved['vid'];native=NativeSessionStore();grant=native.load(owner);journal,receipt,initial,timer,close=stores()
        if timer.backend.load() is not None or close.backend.load() is not None:raise ValueError('resume/consumed')
        def current():return native.load(owner)==grant
        def notes(target):
            data=NotesProbe(target,grant,current,None).observe(grant)
            return data['marks']['updated']=={} and data['marks']['chapters']=={} and data['thoughts']=={}
        def uploader(probe,journal_arg,grant_arg,grant_check,source,*,apply,cleanup_gate):
            if journal_arg is not journal or grant_arg!=grant:raise ValueError('resume/scope')
            return resume_upload(probe,journal,grant,grant_check,source,apply=apply,cleanup_gate=cleanup_gate,
                                 receipt_backend=receipt.backend,notes=notes)
        def after(context,report):return auto_trial(context,report,timer,close,second_command)
        result=run(saved,session,native,grant,journal,initial,first_command,apply=True,uploader=uploader,
            source_format='web_txt',source_marker=MARKER,position_planner=plan,summary_planner=summary,
            upload_success='TXT_IMPORT_AND_SOURCE_VERIFIED',resume_fixture=True,after_verified=after,
            fixture_authorized=lambda j,r,t,o:fixture_authorized(receipt.backend,j,r,t,o))
        if result.get('result')=='CB_FIRST_NATIVE_UI_VERIFIED' and len(result.get('auto_stages',[]))==4:
            result['result']='CB_TXT_AUTO_NATIVE_UI_VERIFIED'
    except Exception:
        result=dict(result='UNVERIFIED',phase='unknown',account_data_writes_known=None,position_writes_uncertain=True)
    finally:
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(result))
    return int(result['result']!='CB_TXT_AUTO_NATIVE_UI_VERIFIED')


if __name__=='__main__':raise SystemExit(main())
