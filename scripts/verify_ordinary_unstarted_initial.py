#!/usr/bin/env python3
"""One first position for the separately verified unstarted-time sample.

Offline by default. A saved-session dry run performs source and state reads
only; --apply claims a new permanent Keychain record before a single native
zero-time position request. The no-chapter state cannot be restored.
"""
import argparse
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import resource
import secrets
import tempfile
import time
from urllib.parse import urlencode

from native_direct_time_trial_store import Intent
from native_initial_position import counts,no_chapter
from native_time_capture_evidence import account_key
from native_txt_read_model import body as position_body
from readtime_upload_model import confirmed,guest_token,local_zone
from secure_native_session import NativeSessionStore,project_lock
from secure_weread_session import ACCOUNT,MacKeychain,SessionStore
from shelf_flag_change_contract import state_hash
from verify_eink_login import BASE as NATIVE,NativeProbe
from verify_native_chapter_package import ChapterProbe
from verify_native_direct_roundtrip import Reads,catalog,current_source,select_target,state
from verify_native_direct_time_trial import web_cookies
from verify_native_thought_trial import other_pending
from verify_ordinary_unstarted_time import store as time_store
from verify_reader_progress import find_node
from verify_web_source_progress import BASE as WEB,WebSourceProbe

SERVICE='org.codex.weread.ordinary-unstarted-first-position-v1'


def store():
    path=Path(tempfile.gettempdir())/('codex-ordinary-unstarted-first-position-'+ACCOUNT+'.lock')
    return Intent(backend=MacKeychain(service=SERVICE,account=ACCOUNT),lock=lambda:project_lock(path))


def chapter_index(web,book,uid):
    raw=web.request('catalog_before',WEB+'/web/book/chapterInfos',{'bookIds':[book]})
    rows=raw.get('data') if isinstance(raw,dict) else None
    books=[row for row in rows or [] if isinstance(row,dict) and str(row.get('bookId'))==book]
    if len(books)!=1 or not isinstance(books[0].get('updated'),list):raise ValueError('unstarted_initial/catalog')
    found=[row for row in books[0]['updated'] if isinstance(row,dict) and str(row.get('chapterUid'))==uid]
    if len(found)!=1 or type(found[0].get('chapterIdx')) is not int or not 0<=found[0]['chapterIdx']<=1000000:
        raise ValueError('unstarted_initial/catalog')
    return found[0]['chapterIdx']


def run(*,apply=False):
    report=dict(result='UNVERIFIED',phase='preflight',account_data_posts=0,authentication_posts=0,
        dispatch_may_have_occurred=False,private_data_in_report=False,original_no_chapter_restored=False)
    web=saved=grant=None;receipt=None
    try:
        prior,prior_raw=time_store().read();intent=store()
        if not prior or prior.get('phase')!='verified' or not isinstance(prior_raw,bytes) or intent.read()!=(None,None) or other_pending():
            raise ValueError('unstarted_initial/pending')
        saved=SessionStore().load();grant=NativeSessionStore().load(saved['vid'])
        def current():return SessionStore().load()==saved and NativeSessionStore().load(saved['vid'])==grant and time_store().read()[1]==prior_raw
        if not current():raise ValueError('unstarted_initial/session')
        prior_plan=prior['plan'];prior_source=prior_plan['record']['source']
        if (prior_plan['record'].get('owner')!=account_key(grant['vid'])
                or prior_plan['selection'].get('duration')!=2 or not isinstance(prior_plan['body'].get('books'),list)
                or len(prior_plan['body']['books'])!=1
                or prior_plan['body']['books'][0].get('bookId')!=prior_source.get('book_id')
                or prior_plan['body']['books'][0].get('readingTime')!=2):
            raise ValueError('unstarted_initial/prior')
        sample,chapter,original=ChapterProbe().inspect(grant,0)
        identity=sample['book_id'];uid=str(chapter['uid']);version=sample['expected']['version']
        if (identity!=prior_source['book_id'] or uid!=prior_source['chapter_uid'] or version!=prior_source['version']
                or hashlib.sha256(original['source']).hexdigest()!=prior_source['source_sha256']
                or sample['expected']['format']!='epub' or not original['html'] or not chapter['free_or_owned']):
            raise ValueError('unstarted_initial/source')
        native=Reads(grant,identity);web=WebSourceProbe();web.vid=saved['vid']
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();web.book_id=identity;web.chapter=uid;cookies=web_cookies(web,saved['vid'])
        index=chapter_index(web,identity,uid);catalog_hash=catalog(web,identity,uid,index)
        raw=current_source(sample,uid,grant,web);source_hash=hashlib.sha256(raw).hexdigest()
        if source_hash!=prior_source['source_sha256']:raise ValueError('unstarted_initial/source')
        target=select_target(raw,dict(book_id=identity,chapter_uid=uid,chapter_idx=index,chapter_offset=-1,raw_percent=0,summary=''))
        native_shelf=state_hash(native.request('shelf',NATIVE+'/shelf/sync',credentials=grant))
        web_shelf=state_hash(web.request('shelf',WEB+'/web/shelf/sync'))
        def baseline():
            n=native.request('progress',NATIVE+'/book/getProgress?'+urlencode({'bookId':identity}),credentials=grant)
            w=web.request('progress_after',WEB+'/web/book/getProgress?'+urlencode({'bookId':identity}))
            return dict(native=no_chapter(n,identity),web=no_chapter(w,identity),native_counts=counts(n,identity),web_counts=counts(w,identity))
        before=baseline();expected_counts={'readingTime':2,'recordReadingTime':0,'ttsTime':0}
        if before['native_counts']!=expected_counts or before['web_counts']!=expected_counts:
            raise ValueError('unstarted_initial/counts')
        def stable():
            if not current() or web_cookies(web,saved['vid'])!=cookies or baseline()!=before:return False
            if state_hash(native.request('shelf',NATIVE+'/shelf/sync',credentials=grant))!=native_shelf:return False
            if state_hash(web.request('shelf',WEB+'/web/shelf/sync'))!=web_shelf:return False
            return True
        if not stable() or catalog(web,identity,uid,index)!=catalog_hash:raise ValueError('unstarted_initial/changed')
        fresh=current_source(sample,uid,grant,web)
        if hashlib.sha256(fresh).hexdigest()!=source_hash or not stable():raise ValueError('unstarted_initial/changed')
        guest,_=guest_token(native.request('feature',NATIVE+'/feature?synckey=0',credentials=grant))
        if local_zone()!='+08:00':raise ValueError('unstarted_initial/clock')
        request=position_body(grant,target,version,guest,int(time.time()),secrets.randbelow(1000),'+08:00')
        if request['readingTime']!=0 or request['hours']!=[]:raise ValueError('unstarted_initial/body')
        if not stable() or catalog(web,identity,uid,index)!=catalog_hash:raise ValueError('unstarted_initial/changed')
        if not 0<=time.time()-request['timestamp']<30:raise ValueError('unstarted_initial/clock')
        if not apply:
            report.update(result='UNSTARTED_INITIAL_DRY_VERIFIED',phase='complete',nonzero_reading_time=2,
                both_sources_no_chapter=True,source_and_target_verified=True)
            return report
        plan=dict(selection=dict(target=target,source_sha256=source_hash,catalog_sha256=catalog_hash),
            record=dict(prior_attempt=prior['attempt'],prior_receipt_sha256=hashlib.sha256(prior_raw).hexdigest(),
                native_shelf=native_shelf,web_shelf=web_shelf,version=version),body=deepcopy(request),baseline=before)
        receipt=intent.claim(plan)
        value,raw_receipt=intent.read()
        if raw_receipt!=receipt or not value or value['phase']!='claimed' or value['plan']!=plan \
                or not stable() or not 0<=time.time()-request['timestamp']<30:
            raise ValueError('unstarted_initial/claim')
        report.update(phase='dispatch',account_data_posts=None,dispatch_may_have_occurred=True)
        response=NativeProbe.request(NativeProbe(),'unstarted_initial_write',NATIVE+'/book/read',body=request,credentials=grant,timeout=20)
        if not confirmed(response):raise ValueError('unstarted_initial/receipt')
        report['account_data_posts']=1;receipt=intent.advance(receipt,'acknowledged');report['phase']='readback'
        previous=None;stable_reads=0
        def classify(raw,channel):
            try:
                point,_=state(raw,identity,channel)
                if point==target:return 'target'
            except ValueError:pass
            try:
                if no_chapter(raw,identity)==before[channel]:return 'before'
            except ValueError:pass
            raise ValueError('unstarted_initial/position')
        for attempt in range(5):
            if attempt:time.sleep(2)
            n=native.request('progress',NATIVE+'/book/getProgress?'+urlencode({'bookId':identity}),credentials=grant)
            w=web.request('progress_after',WEB+'/web/book/getProgress?'+urlencode({'bookId':identity}))
            if counts(n,identity)!=expected_counts or counts(w,identity)!=expected_counts:raise ValueError('unstarted_initial/counts')
            nstate,wstate=classify(n,'native'),classify(w,'web')
            if nstate=='target' and wstate=='target':
                value=(nstate,wstate);stable_reads=stable_reads+1 if value==previous else 1;previous=value
                if stable_reads>=2:break
            else:
                stable_reads=0;previous=None
        if stable_reads<2 or not current() or web_cookies(web,saved['vid'])!=cookies:raise ValueError('unstarted_initial/readback')
        if state_hash(native.request('shelf',NATIVE+'/shelf/sync',credentials=grant))!=native_shelf \
                or state_hash(web.request('shelf',WEB+'/web/shelf/sync'))!=web_shelf \
                or catalog(web,identity,uid,index)!=catalog_hash \
                or hashlib.sha256(current_source(sample,uid,grant,web)).hexdigest()!=source_hash:
            raise ValueError('unstarted_initial/changed')
        intent.advance(receipt,'verified')
        report.update(result='UNSTARTED_INITIAL_POSITION_VERIFIED',phase='complete',reading_time_preserved=2,
            independent_readbacks=stable_reads,source_and_shelf_unchanged=True,prior_record_unchanged=True,
            one_shot_record_retained=True)
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
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));result=run(apply=args.apply);print(json.dumps(result))
    return int(result['result'] not in ('UNSTARTED_INITIAL_DRY_VERIFIED','UNSTARTED_INITIAL_POSITION_VERIFIED'))


if __name__=='__main__':raise SystemExit(main())
