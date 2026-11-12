#!/usr/bin/env python3
"""Validate literal raw-30 summaries with a new native advance/restore scope.

Offline by default. One pair of zero-time writes at most; full restoration
data is Keychain-only. No replay, automatic renewal or Web write endpoint.
"""
import argparse
from datetime import datetime,timezone
import json
import resource
from secure_weread_session import SessionStore
from secure_native_session import NativeSessionStore
from secure_raw_txt_excerpt import RawTxtExcerptStore,validate_plan
from txt_coordinates import PlainSource
from txt_full_summary import digest
from verify_native_txt_position import Source,inspect
from verify_native_txt_roundtrip import Probe,compact,source_hash,catalog_hash,check,run
from verify_translation_preflight import save_refreshed_web_session
from verify_reader_progress import find_node
from verify_web_source_progress import BASE as WEB
from shelf_flag_change_contract import state_hash


def candidate(raw,source):
    """Use exact raw bytes/scalars, never slide the observed app summary."""
    if (source.get('basis')!='raw_txt_utf16' or not source.get('summary_unique_start_matches')
            or not source.get('target')):raise ValueError('raw_txt_excerpt/source')
    original=compact(source['baseline']);target=compact(source['target'])
    if target['chapter_offset']!=original['chapter_offset']+1:raise ValueError('raw_txt_excerpt/boundary')
    model=PlainSource(raw);value=model.excerpt(target['chapter_offset'])
    if value['scalars']!=30:raise ValueError('raw_txt_excerpt/short')
    target['summary']=value['text']
    return original,target


def make_plan(web,native,credentials,report):
    source=web.inspect_plan();original,target=candidate(web.sample['plain'],source)
    observation=inspect(web,native,credentials,source,report)
    plan=dict(protocol=RawTxtExcerptStore.protocol,owner_sha256=digest(web.vid),source_sha256=source_hash(web),
              catalog_sha256=catalog_hash(web),grant_sha256=digest(credentials),
              shelf_sha256=state_hash(web.request('shelf',WEB+'/web/shelf/sync')),baseline=original,target=target,
              counts=observation['counts'],version=observation['version'],
              chapter_progress=find_node(observation['native_progress'],web.book_id).get('chapterProgress'))
    validate_plan(plan)
    report.update(target_summary_scalars=30,target_summary_contains_crlf='\r\n' in target['summary'],
                  original_summary_preserved_in_plan=True,official_summary_rule_claimed=False)
    return plan,observation['guest']


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--saved-session',action='store_true')
    modes=p.add_mutually_exclusive_group();modes.add_argument('--apply',action='store_true')
    modes.add_argument('--resolve',action='store_true');modes.add_argument('--restore-only',action='store_true');a=p.parse_args(argv)
    if (a.apply or a.resolve or a.restore_only) and not a.saved_session:p.error('saved session required')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,
                authentication_posts=0,web_write_posts=0,historical_time_rows=0,private_data_on_regular_disk=False,
                production_upload_enabled=False)
    store=web=native=saved=credentials=session=None
    try:
        if a.saved_session:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0))
            from verify_native_thought_trial import other_pending
            if other_pending(exclude_raw_txt_excerpt=a.resolve or a.restore_only):raise ValueError('raw_txt_excerpt/pending')
            store=RawTxtExcerptStore();state,_r=store.read()
            if a.apply and state is not None:raise ValueError('raw_txt_excerpt/consumed')
            session=SessionStore();saved=session.load();credentials=NativeSessionStore().load(saved['vid'])
            web=Source();web.vid=saved['vid']
            if state and (a.resolve or a.restore_only) and digest(web.vid)!=state['plan']['owner_sha256']:raise ValueError('raw_txt_excerpt/owner')
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account()
            identity=state['plan']['baseline']['book_id'] if state and (a.resolve or a.restore_only) else None
            if not web.find_sample(book_id=identity,limit=16):raise ValueError('raw_txt_excerpt/no_sample')
            native=Probe(credentials,web.book_id,restore_only=a.restore_only)
            run(web,native,credentials,session,saved,store,report,apply=a.apply,resolving=a.resolve,
                restore_only=a.restore_only,planner=make_plan,summary_method='literal_raw_30')
            if a.apply or a.restore_only or a.resolve:
                state,_r=store.read()
                if state and state['phase'] in ('retired','restored_advance_unverified','closed_advance_unverified','closed_restore_unverified'):
                    for _i in range(2):check(web,native,credentials,state['plan'],state['plan']['baseline'],refresh=True)
                    report['final_independent_original_checks']=2
            if a.apply and report.get('target_readback') and report.get('original_readback'):
                report.update(result='NATIVE_LITERAL_TXT_SUMMARY_PROTOCOL_VERIFIED',literal_source_summary_readback_verified=True)
            elif not (a.resolve or a.restore_only):report['result']='NATIVE_LITERAL_TXT_SUMMARY_PLAN_VERIFIED'
    except (Exception,KeyboardInterrupt) as error:
        report['result']='UNVERIFIED'
        reason=str(error)
        if reason in {'raw_txt_excerpt/pending','raw_txt_excerpt/consumed','raw_txt_excerpt/owner','raw_txt_excerpt/no_sample',
                      'txt_roundtrip/unknown_readback','txt_roundtrip/readback_pending','txt_roundtrip/ack','txt_roundtrip/source',
                      'txt_roundtrip/version','txt_roundtrip/grant','txt_roundtrip/position','native_txt/time_changed','native_txt/shelf_changed'}:
            report['reason']=reason
    finally:
        if web:
            if web.authenticated:
                try:web.verify_account();save_refreshed_web_session(session,session.load(),web)
                except Exception:report['result']='UNVERIFIED'
            report['web_stages']=[{k:r[k] for k in ('stage','status','api_code') if k in r} for r in web.report['stages']]
            web.sample=None;web.close()
        if native:
            report['account_data_posts']=native.posts
            report['native_stages']=[{k:r[k] for k in ('stage','status','error_code') if k in r} for r in native.report['stages']]
        if store:
            try:
                state,_r=store.read();report['intent_phase']=state['phase'] if state else 'absent'
                report['consumed_slots']=state['posts'] if state else 0
            except Exception:report['intent_phase']='unverified'
        for value in (saved,credentials):
            if value:value.clear()
    print(json.dumps(report,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
