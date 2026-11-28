#!/usr/bin/env python3
"""Prepare, or explicitly execute, one source-bound native four-POST experiment.

Default offline. --saved-session only prepares a private plan fingerprint.
Execution additionally needs --apply, that exact --expected-plan, and the
guarded Lua runner command. A persisted Keychain intent precedes the child;
unknown results retain it and cannot automatically execute a new experiment.
"""
import argparse
from datetime import datetime,timezone
import hashlib
import json
import re
import subprocess
import time

from secure_weread_session import SessionStore
from secure_position_experiment import ExperimentStore,binding,fingerprint
from verify_owner_progress_preview import Preflight
from verify_position_roundtrip import same_position
from verify_reader_progress import project,find_node
from verify_web_source_progress import BASE
from verify_translation_preflight import save_refreshed_web_session
from owner_progress_roundtrip_contract import decode,compare


def original_position(raw,plan):
    value=project(raw,plan['book_id']);node=find_node(raw,plan['book_id'])
    return (any(k in node for k in ('chapterIdx','chapterIndex','chapter_idx'))
            and value.get('chapter_uid') is not None and value['has_chapter_offset'] and same_position(value,plan['baseline']))


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--apply',action='store_true')
    parser.add_argument('--check-only',action='store_true')
    parser.add_argument('--expected-plan')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if (args.apply and args.check_only or (args.apply or args.check_only)!=bool(args.lua_command)
            or args.check_only and not args.saved_session or args.apply and (not args.saved_session or not isinstance(args.expected_plan,str)
            or not re.fullmatch('[0-9a-f]{64}',args.expected_plan)) or args.expected_plan and not args.apply):
        parser.error('execution requires --saved-session --apply --expected-plan and --lua-command last')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_writes_attempted=0,
                authentication_posts_attempted=0,private_data_on_regular_disk=False,screenshots=0,intent_state='none',
                real_plugin_write_verified=False,source_upload_gate_enabled=False)
    saved=web=payload=envelope=receipt=intents=None
    try:
        if args.saved_session:
            intents=ExperimentStore()
            report['pending_intent_present']=intents.pending()
            if report['pending_intent_present']:report['intent_state']='pending'
            if args.apply and report['pending_intent_present']:raise ValueError('position_experiment_unconfirmed')
            store,web=SessionStore(),Preflight()
            saved=store.load();web.vid=saved['vid']
            if args.apply and saved.get('web',{}).get('renewal_pending'):raise ValueError('position_authentication_unconfirmed')
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account()
            try:payload=web.prepare()
            finally:
                web.verify_account()
                report['preflight_rotation_saved']=save_refreshed_web_session(store,saved,web);saved=store.load()
            bound=binding(web.vid,web.plan,payload['source_raw_sha256'])
            digest=fingerprint(bound)
            report.update(result='BOUNDED_NATIVE_EXPERIMENT_PLAN_READY',plan_fingerprint=digest,planned_post_limit=4,
                          probe_utf16_delta=1,planned_elapsed_seconds=0,recent_read_metadata_may_update=True,
                          same_position_summary_preserved=web.plan['same_position_summary_preserved'])
            if args.apply or args.check_only:
                if args.apply:
                    if digest!=args.expected_plan:raise ValueError('position_plan_changed')
                    # A save may succeed even if its subsequent readback fails.
                    report['intent_state']='unknown'
                    receipt=intents.begin(bound)
                    intent_digest=hashlib.sha256(receipt.pending).hexdigest()
                    report.update(intent_state='pending',intent_readback_verified=True,account_data_writes_attempted=None)
                else:intent_digest=''
                report['result']='UNVERIFIED'
                points=payload.pop('progress_preview')
                payload.update(vid=web.vid,cookies=saved['cookies'],progress_roundtrip=dict(points,permit_writes=args.apply,intent_digest=intent_digest))
                raw=json.dumps(payload,ensure_ascii=False).encode()
                if len(raw)>256*1024:
                    if receipt is not None:
                        intents.finish(receipt,not_dispatched=True);receipt=None;report['intent_state']='cleared'
                    raise ValueError('position_input_limit')
                started=int(time.time())
                try:child=subprocess.run(args.lua_command,input=raw,capture_output=True,timeout=240)
                except FileNotFoundError:
                    if receipt is not None:
                        intents.finish(receipt,not_dispatched=True);receipt=None;report['intent_state']='cleared'
                    report['account_data_writes_attempted']=0
                    raise
                finished=int(time.time())
                envelope=decode(child.stdout,web.vid);report['ui']=envelope['report']
                private=envelope['progress_private']
                if private is None or private['intent_digest']!=intent_digest:raise ValueError('position_receipt_unverified')
                addon=report['ui']['stages'][0]['progress_roundtrip']
                compare(private['records'],web.plan,started,finished)
                report['account_data_writes_attempted']=addon['posts_attempted']
                if args.apply:report['independent_payloads_verified']=True
                web.cookies.clear()
                for key,value in envelope['cookies'].items():web.set_cookie(key,value)
                web.verify_account()
                raw=web.request('progress_after',BASE+'/web/book/getProgress?bookId='+web.book_id)
                report['independent_original_position_verified']=original_position(raw,web.plan)
                report['final_rotation_saved']=save_refreshed_web_session(store,saved,web)
                if args.check_only:
                    stage=report['ui']['stages'][0]
                    if (not addon['disarmed'] or not addon['permission_blocked'] or addon['posts_attempted']
                            or not addon['source_points_verified'] or not addon['reader_position_restored'] or addon['guard_denied']
                            or stage['result']!='PASS' or not report['ui']['profile_removed'] or not report['independent_original_position_verified']):
                        raise ValueError('position_disarmed_check_unverified')
                    report.update(result='OWNER_NATIVE_EXECUTOR_DISARMED_VERIFIED',pre_dispatch_guard_verified=True)
                elif addon['posts_attempted']==0:
                    intents.finish(receipt,not_dispatched=True);receipt=None;report['intent_state']='cleared'
                elif addon['safe_resolution'] and report['independent_original_position_verified']:
                    intents.finish(receipt,restored_verified=True);receipt=None;report['intent_state']='cleared'
                if args.apply and (child.returncode or report['ui']['result']!='PASS' or addon['result']!='PASS'
                        or report['intent_state']!='cleared' or not report['independent_original_position_verified']):raise ValueError('position_experiment_unverified')
                if args.apply:
                    report.update(result='OWNER_NATIVE_POSITION_ROUNDTRIP_VERIFIED',real_plugin_write_verified=True,
                                  payloads_compared=4,restoration_verified=True,synthetic_acknowledgements=0)
    except KeyboardInterrupt:
        report.update(result='UNVERIFIED',reason='position_experiment_interrupted')
    except Exception as exc:
        report.update(result='UNVERIFIED',reason='position_experiment_unverified')
        known={'position_experiment_unconfirmed','position_authentication_unconfirmed','position_plan_changed',
               'position_receipt_unverified','position_intent_readback_failed','position_intent_cleanup_unverified'}
        if str(exc) in known:report['detail']=str(exc)
        if str(exc)=='position_intent_cleanup_unverified':report['intent_state']='unknown'
    finally:
        if receipt is not None and report['intent_state']!='unknown':report['intent_state']='pending'
        if web:
            report['preflight_stages']=[{k:row[k] for k in ('stage','status','api_code') if k in row} for row in web.report['stages']]
            web.shards.clear();web.raw_progress=web.reader=web.plan=None;web.close()
        for value in (saved,payload,envelope):
            if value:value.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2))
    return 0 if report['result'] in ('OFFLINE_ONLY','BOUNDED_NATIVE_EXPERIMENT_PLAN_READY','OWNER_NATIVE_POSITION_ROUNDTRIP_VERIFIED','OWNER_NATIVE_EXECUTOR_DISARMED_VERIFIED') else 1


if __name__=='__main__':raise SystemExit(main())
