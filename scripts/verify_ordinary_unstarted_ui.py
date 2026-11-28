#!/usr/bin/env python3
"""Independent supervisor for one installed-reader initial-position trial.

Offline unless --saved-session is supplied. --apply enables one dispatch only
when a separately verified two-second sample and all fresh checks agree.
"""
import argparse
import hashlib
import json
import resource
import secrets
import time
from urllib.parse import urlencode

from native_direct_initial_ui_broker import execute
from native_initial_position import counts,no_chapter
from native_time_capture_evidence import account_key
from ordinary_unstarted_ui_prior import OrdinaryUnstartedUiTimeStore,OrdinaryUnstartedUiPositionStore,PreviousSamples,inspect_book
from readtime_upload_model import guest_token,local_zone
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from shelf_flag_change_contract import state_hash
from verify_cb_native_time_guarded_dry import trusted_command
from verify_eink_login import BASE as NATIVE
from verify_native_direct_roundtrip import Reads,catalog,current_source,state
from verify_native_direct_time_trial import web_cookies
from verify_native_statistics import period
from verify_native_thought_trial import other_pending
from verify_ordinary_unstarted_initial import chapter_index,store as old_position_store
from verify_ordinary_unstarted_time import store as old_time_store
from verify_web_source_progress import BASE as WEB,WebSourceProbe


def command(armed):
    known=trusted_command();index=known.index('--candidate')
    if index+1>=len(known) or len(known)!=index+2:raise ValueError('ordinary_ui/command')
    result=known[:6]+['python3','scripts/run_native_direct_initial_ui.py','--koreader',
        '/validation/runtime/lib/koreader','--candidate',known[index+1]]
    if armed:result.append('--armed')
    return result


def run(*,apply=False):
    report=dict(result='UNVERIFIED',phase='preflight',account_data_posts=0,authentication_posts=0,
        dispatch_may_have_occurred=False,private_data_in_report=False,original_no_chapter_restored=False)
    web=saved=grant=None
    try:
        if type(apply) is not bool or other_pending():raise ValueError('ordinary_ui/pending')
        timing=OrdinaryUnstartedUiTimeStore();position=OrdinaryUnstartedUiPositionStore()
        prior,prior_raw=timing.read()
        if not prior or prior['phase']!='verified' or not isinstance(prior_raw,bytes) or position.read()!=(None,None):
            raise ValueError('ordinary_ui/time')
        saved=SessionStore().load();grant=NativeSessionStore().load(saved['vid'])
        preceding=PreviousSamples(old_time_store(),old_position_store())
        source=prior['plan']['record']['source']
        preceding.check(grant,source,dict(protocol_rows=[prior['plan']['selection']]))
        if (prior['plan']['record']['owner']!=account_key(grant['vid']) or prior['plan']['selection']['duration']!=2
                or len(prior['plan']['body']['books'])!=1
                or prior['plan']['body']['books'][0]['bookId']!=source['book_id']
                or prior['plan']['body']['books'][0]['readingTime']!=2):raise ValueError('ordinary_ui/time')
        sample,chapter,original=inspect_book(grant,source['book_id'])
        book=sample['book_id'];uid=str(chapter['uid']);version=sample['expected']['version']
        if (book!=source['book_id'] or uid!=source['chapter_uid'] or version!=source['version']
                or sample['expected']['format']!='epub' or not original['html'] or not chapter['free_or_owned']
                or hashlib.sha256(original['source']).hexdigest()!=source['source_sha256']):raise ValueError('ordinary_ui/source')
        web=WebSourceProbe();web.vid=saved['vid']
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();web.book_id=book;web.chapter=uid;cookies=web_cookies(web,saved['vid'])
        index=chapter_index(web,book,uid);catalog_hash=catalog(web,book,uid,index)
        raw=current_source(sample,uid,grant,web)
        if hashlib.sha256(raw).hexdigest()!=source['source_sha256']:raise ValueError('ordinary_ui/source')
        native=Reads(grant,book)
        native_shelf=state_hash(native.request('shelf',NATIVE+'/shelf/sync',credentials=grant))
        web_shelf=state_hash(web.request('shelf',WEB+'/web/shelf/sync'))
        expected_counts=dict(readingTime=2,recordReadingTime=0,ttsTime=0)
        def pair():
            n=native.request('progress',NATIVE+'/book/getProgress?'+urlencode({'bookId':book}),credentials=grant)
            w=web.request('progress_after',WEB+'/web/book/getProgress?'+urlencode({'bookId':book}))
            if counts(n,book)!=expected_counts or counts(w,book)!=expected_counts:raise ValueError('ordinary_ui/counts')
            return n,w
        n,w=pair();native_before=no_chapter(n,book);web_before=no_chapter(w,book)
        expected=dict(book_id=book,uid=uid,chapter_idx=index,native_before=native_before,web_before=web_before,
            counts=expected_counts,version=version,native_shelf=native_shelf,web_shelf=web_shelf,
            source_sha256=source['source_sha256'],catalog_sha256=catalog_hash)
        def current():
            preceding.check(grant,source)
            return (SessionStore().load()==saved and NativeSessionStore().load(saved['vid'])==grant
                and timing.read()==(prior,prior_raw) and web_cookies(web,saved['vid'])==cookies
                and not other_pending(exclude_ordinary_ui_position=True))
        def unchanged():
            if (state_hash(native.request('shelf',NATIVE+'/shelf/sync',credentials=grant))!=native_shelf
                    or state_hash(web.request('shelf',WEB+'/web/shelf/sync'))!=web_shelf
                    or catalog(web,book,uid,index)!=catalog_hash
                    or hashlib.sha256(current_source(sample,uid,grant,web)).hexdigest()!=source['source_sha256']):
                raise ValueError('ordinary_ui/changed')
        def before(_metadata):
            for _ in range(2):
                n,w=pair()
                if no_chapter(n,book)!=native_before or no_chapter(w,book)!=web_before:raise ValueError('ordinary_ui/baseline')
            unchanged();return True
        def after(metadata):
            stable=0
            for attempt in range(5):
                if attempt:time.sleep(2)
                n,w=pair()
                try:observed=(state(n,book,'native')[0],state(w,book,'web')[0])
                except ValueError:observed=(None,None)
                stable=stable+1 if observed==(metadata['desired'],metadata['desired']) else 0
                if stable>=2:break
            if stable<2:raise ValueError('ordinary_ui/readback')
            unchanged();return True
        guest,_=guest_token(native.request('feature',NATIVE+'/feature?synckey=0',credentials=grant))
        if local_zone()!='+08:00' or not current() or not before(None):raise ValueError('ordinary_ui/preflight')
        payload=dict(token=secrets.token_hex(16),armed=apply,expected=expected,credentials=grant,guest=guest,time_zone='+08:00',
            book_id=book,uid=uid,book_version=version,source_sha256=source['source_sha256'],web_cookies=cookies,
            months=[period('monthly',int(time.time()))[0]])
        report['phase']='ui'
        execute(payload,command(apply),position,raw,report,current=current,before=before,after=after)
        report.update(phase='complete',reading_time_preserved_seconds=2,prior_records_unchanged=True,
            first_position_remains_established=apply,physical_kindle_tested=False)
    except (Exception,KeyboardInterrupt):
        pass
    finally:
        if web:web.close()
        if saved:saved.clear()
        if grant:grant.clear()
    return report


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--apply',action='store_true');args=parser.parse_args(argv)
    if args.apply and not args.saved_session:parser.error('apply requires saved session')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));report=run(apply=args.apply);print(json.dumps(report))
    return int(report['result'] not in ('INITIAL_NATIVE_UI_DRY_VERIFIED','INITIAL_NATIVE_UI_VERIFIED'))


if __name__=='__main__':raise SystemExit(main())
