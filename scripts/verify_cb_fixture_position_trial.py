#!/usr/bin/env python3
"""One isolated uploaded EPUB and bounded CB position/long-summary trial.

Offline by default. Apply creates one new self-authored book using a new
permanent no-replay journal. Only that new book can receive four ordered
zero-time position requests. Unknown effects block automatic fixture cleanup.
"""
import argparse
import json
from pathlib import Path
import resource
import tempfile

from cb_fixture_position import plan as position_plan
from cb_fixture_position_intent import Intent
from cb_fixture_position_transport import Probe as PositionProbe
from secure_native_session import NativeSessionStore,project_lock
from secure_weread_session import ACCOUNT,MacKeychain,SessionStore
from synthetic_epub_trial import Journal
from synthetic_upload_epub import TEXT
from verify_cb_progress import cb_id
from verify_cb_reading import CbReadingProbe
from verify_personal_upload_trial import Probe as UploadProbe
from verify_synthetic_epub_upload import run as run_upload
from verify_translation_preflight import save_refreshed_web_session

UPLOAD_SERVICE='org.codex.weread.cb-position-fixture-upload-v1'


def make_journal():
    backend=MacKeychain(service=UPLOAD_SERVICE,account=ACCOUNT)
    path=Path(tempfile.gettempdir())/('codex-cb-position-fixture-upload-'+ACCOUNT+'.lock')
    return Journal(backend=backend,lock=lambda:project_lock(path))


def owned(journal,receipt,target,owner,grant,same_grant):
    state,current=journal.read()
    return bool(state and current==receipt and state['phase']=='imported' and state['target']==target
                and state['plan']['owner']==owner and same_grant(grant))


def run(saved,store,native,grant,journal,intent,*,apply=False,upload_factory=UploadProbe,upload_run=run_upload):
    report=dict(result='UNVERIFIED',phase='preflight',account_data_writes=0,authentication_writes=0,
                fixture_only=True,private_data_in_report=False,write_authority_for_existing_books=False)
    current={'saved':saved,'plan':None,'source_verified':False,'position':None}
    def same_grant(value):return native.load(current['saved']['vid'])==value
    def read_source(target):
        web=CbReadingProbe();web.vid=current['saved']['vid'];web.allowed={target}
        try:
            for key,value in current['saved']['cookies'].items():web.set_cookie(key,value)
            web.verify_account();sample=web.inspect(target);web.verify_account()
            valid=(cb_id(target) is not None and sample['book_id']==target and sample['source_format']=='web_xhtml'
                   and TEXT in sample['source'] and set(web.last_checks)=={'catalog_unchanged','versions_unchanged','position_unchanged'}
                   and all(value is True for value in web.last_checks.values()))
            if valid:
                try:current['plan']=position_plan(target,sample)
                except Exception:current['plan']=None
            current['source_verified']=valid
            return valid
        finally:
            if web.authenticated:
                if save_refreshed_web_session(store,current['saved'],web):
                    old=current['saved'];current['saved']=store.load()
                    if current['saved']['vid']!=old['vid']:raise ValueError('fixture_position/owner')
                    old.clear()
            web.samples.clear();web.close()
    def trial(upload_journal,receipt,_upload_plan,target):
        if not current['source_verified'] or current['plan'] is None:
            report['position_plan_available']=False
            return True  # No position dispatch; the exact owned fixture may be cleaned.
        report['position_plan_available']=True
        owner=current['saved']['vid']
        if not owned(upload_journal,receipt,target,owner,grant,same_grant):return False
        state,_=upload_journal.read();attempt=state['attempt']
        reserved=intent.reserve(owner,target,attempt)
        def authority():
            return owned(upload_journal,receipt,target,owner,grant,same_grant) and intent.verify(reserved,owner,target,attempt)
        web=PositionProbe(current['plan'],owner,authority)
        try:
            for key,value in current['saved']['cookies'].items():web.set_cookie(key,value)
            web.verify_account()
            current['position']=web.execute(dict(chapter_uid=0,chapter_offset=0,raw_percent=0))
            report['account_data_writes']=current['position']['writes']
            return current['position']['result']=='PASS'
        finally:
            if web.authenticated:
                if save_refreshed_web_session(store,current['saved'],web):
                    old=current['saved'];current['saved']=store.load()
                    if current['saved']['vid']!=old['vid']:raise ValueError('fixture_position/owner')
                    old.clear()
            web.close()
    try:
        if intent.backend.load() is not None:raise ValueError('fixture_position/already_reserved')
        web=CbReadingProbe();web.vid=current['saved']['vid']
        try:
            for key,value in current['saved']['cookies'].items():web.set_cookie(key,value)
            web.verify_account()
            if save_refreshed_web_session(store,current['saved'],web):
                old=current['saved'];current['saved']=store.load()
                if current['saved']['vid']!=old['vid']:raise ValueError('fixture_position/owner')
                old.clear()
        finally:web.close()
        upload=upload_factory(journal,same_grant)
        result=upload_run(upload,journal,grant,same_grant,read_source,apply=apply,cleanup_gate=trial)
        report['upload']=result
        report['account_data_writes']+=result.get('cos_put_attempts',0)+result.get('notify_posts',0)+result.get('cleanup_posts',0)
        report['phase']=result.get('phase','unknown')
        if current['position'] is not None:report['position']=current['position']
        if result.get('result')=='READ_ONLY_PREVIEW':report['result']='READ_ONLY_PREVIEW'
        elif result.get('result')=='EPUB_IMPORT_AND_SOURCE_VERIFIED':
            report['result']='FIXTURE_POSITION_VERIFIED' if current['position'] and current['position']['result']=='PASS' else 'FIXTURE_PLAN_UNAVAILABLE'
    except Exception:
        report['result']='UNVERIFIED'
    finally:
        current['plan']=None
        if current['saved'] is not saved and saved:saved.clear()
        if current['saved']:current['saved'].clear()
    return report


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true');parser.add_argument('--apply',action='store_true')
    args=parser.parse_args(argv)
    if args.apply and not args.saved_session:parser.error('apply requires saved session')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY',account_data_writes=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=None
    try:
        store=SessionStore();saved=store.load();native=NativeSessionStore();grant=native.load(saved['vid'])
        report=run(saved,store,native,grant,make_journal(),Intent(),apply=args.apply)
    except Exception:report=dict(result='UNVERIFIED',account_data_writes=0)
    finally:
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(report));return int(report['result'] not in ('READ_ONLY_PREVIEW','FIXTURE_POSITION_VERIFIED','FIXTURE_PLAN_UNAVAILABLE'))


if __name__=='__main__':raise SystemExit(main())
