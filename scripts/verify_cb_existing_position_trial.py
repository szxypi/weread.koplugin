#!/usr/bin/env python3
"""One permanent, bounded existing-CB position test; offline by default.

Source, full summary, position and credentials stay in memory. A distinct
Keychain reservation prevents replay after any attempted dispatch or restart.
"""
import argparse
from copy import deepcopy
import hashlib
import json
import resource
import secrets

from cb_cloud_position import observed,state
from cb_existing_position_intent import Intent
from cb_existing_position_transport import Probe
from secure_weread_session import SessionStore
from verify_cb_cloud_position import Web
from verify_cb_full_summary_payload import compare,vectors
from verify_cb_progress import cb_ids
from verify_cb_roundtrip_preflight import assess
from verify_cb_source_currentness import descriptor
from verify_position_roundtrip import canonical
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE,WebSourceProbe


def choose(sample,raw):
    book=sample['book_id'];point=state(raw,book,sample['chapters'],'web')
    source=descriptor(sample,point)
    if not source:return None
    plan=assess(book,raw,sample['context'],sample['source'])
    if not plan or plan['target']['chapter_offset']!=plan['baseline']['chapter_offset']+1:return None
    if (str(plan['baseline']['chapter_uid'])!=source['chapter_uid']
            or plan['baseline']['chapter_idx']!=source['chapter_idx']):return None
    try:original=vectors(plan,raw)
    except ValueError:return None
    summary=original[0]['expected']['sm']
    plan['baseline']['summary']=summary;plan['target']['summary']=summary
    advanced=deepcopy(plan);advanced['baseline']=deepcopy(plan['target'])
    target_vectors=vectors(advanced,raw)
    return plan,[original[0],original[1],target_vectors[1],original[1]]


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true');parser.add_argument('--apply',action='store_true')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if args.apply and not args.saved_session or args.saved_session and not args.lua_command:
        parser.error('online operation requires saved session and independent Lua model')
    if args.lua_command and not args.saved_session:parser.error('Lua command requires saved session')
    report=dict(result='OFFLINE_ONLY',account_data_writes=0,authentication_writes=0,
                private_data_in_report=False,no_replay=True,position_unchanged=None,shelf_order_unchanged=None)
    if not args.saved_session:
        print(json.dumps(report));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    saved=web=probe=after=None;baseline=book=chapters=None;phase='session'
    try:
        store=SessionStore();saved=store.load();web=Web();web.vid=saved['vid']
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();shelf=web.request('shelf',BASE+'/web/shelf/sync');ids=cb_ids(shelf);web.allowed=set(ids)
        shelf_ids=[str(row['bookId']) for row in shelf['books']]
        phase='source';selected=None
        for book in ids:
            sample=web.inspect(book);raw=web.progress[(book,'progress_before')]
            candidate=choose(sample,raw)
            if candidate:
                plan,models=candidate;chapters=sample['chapters'];baseline=observed(raw,book,chapters,'web')
                selected=True;break
        if not selected:raise ValueError('cb_existing/no_sample')
        compare(models,args.lua_command);web.verify_account()
        if save_refreshed_web_session(store,saved,web):
            previous=saved;saved=store.load()
            if saved['vid']!=previous['vid']:raise ValueError('cb_existing/owner')
            previous.clear()
        report.update(result='READ_ONLY_READY',lua_payloads_compared=4,source_verified=True)
        if args.apply:
            phase='reservation'
            intent=Intent();fingerprint=hashlib.sha256(canonical(baseline).encode()).hexdigest()
            reservation=intent.reserve(saved['vid'],book,secrets.token_hex(16),fingerprint)
            probe=Probe(plan,saved['vid'],chapters,intent,reservation)
            for key,value in saved['cookies'].items():probe.set_cookie(key,value)
            probe.verify_account();phase='dispatch'
            trial=probe.execute(baseline)
            report.update(trial=trial,account_data_writes=trial['writes'],result='TRIAL_COMPLETE' if trial['result']=='PASS' else 'UNVERIFIED')
            probe.verify_account()
            if save_refreshed_web_session(store,saved,probe):
                previous=saved;saved=store.load()
                if saved['vid']!=previous['vid']:raise ValueError('cb_existing/owner')
                previous.clear()
        phase='after';after=WebSourceProbe();after.vid=saved['vid'];after.book_id=book;after.chapter=sample['chapter_uid']
        for key,value in saved['cookies'].items():after.set_cookie(key,value)
        after.verify_account();latest=after.request('progress_after',BASE+'/web/book/getProgress?bookId='+book)
        report['position_unchanged']=observed(latest,book,chapters,'web')==baseline
        final_shelf=after.request('shelf',BASE+'/web/shelf/sync');after.verify_account()
        report['shelf_order_unchanged']=[str(row['bookId']) for row in final_shelf['books']]==shelf_ids
        if not report['position_unchanged'] or not report['shelf_order_unchanged']:report['result']='UNVERIFIED'
    except Exception:
        report.update(result='UNVERIFIED',failure_stage=phase)
        if probe:report['account_data_writes']=probe.writes
        # A transport failure does not establish that a write was rejected.
        # Independently read the original book and shelf even on interruption;
        # never dispatch another write from this recovery path.
        if probe and saved and baseline and after is None:
            try:
                after=WebSourceProbe();after.vid=saved['vid'];after.book_id=book;after.chapter=sample['chapter_uid']
                for key,value in saved['cookies'].items():after.set_cookie(key,value)
                after.verify_account()
                latest=after.request('progress_after',BASE+'/web/book/getProgress?bookId='+book)
                report['position_unchanged']=observed(latest,book,chapters,'web')==baseline
                final_shelf=after.request('shelf',BASE+'/web/shelf/sync');after.verify_account()
                report['shelf_order_unchanged']=[str(row['bookId']) for row in final_shelf['books']]==shelf_ids
            except Exception:pass
    finally:
        if web:
            if not after and not probe and saved and web.authenticated:
                try:save_refreshed_web_session(store,saved,web)
                except Exception:report['result']='UNVERIFIED'
            web.samples.clear();web.progress.clear();web.close()
        if probe:
            if not after and saved and probe.authenticated:
                try:save_refreshed_web_session(store,saved,probe)
                except Exception:report['result']='UNVERIFIED'
            probe.close()
        if after:
            if saved and after.authenticated:
                try:save_refreshed_web_session(store,saved,after)
                except Exception:report['result']='UNVERIFIED'
            after.close()
        if saved:saved.clear()
    print(json.dumps(report));return int(report['result'] not in ('READ_ONLY_READY','TRIAL_COMPLETE'))


if __name__=='__main__':raise SystemExit(main())
