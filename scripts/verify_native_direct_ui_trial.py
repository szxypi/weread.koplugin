#!/usr/bin/env python3
"""Supervise one native ReaderUI advance and exact restore, without replay.

Credentials and source remain in memory; a two-slot recovery intent is saved
to Keychain before any authorized POST. Without --apply every POST is blocked.
"""
import argparse
from copy import deepcopy
import hashlib
import json
import resource
import secrets
import time
from urllib.parse import urlencode

from native_chapter_remote_reference import search_token
from native_direct_ui_trial_broker import PROTOCOL,execute
from readtime_upload_model import guest_token,local_zone
from secure_native_direct_ui_trial import NativeDirectUITrialStore,NativeDirectIntervalTrialStore
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from shelf_flag_change_contract import state_hash
from txt_full_summary import digest
from verify_eink_login import BASE
from verify_native_chapter_package import ChapterProbe
from verify_native_direct_roundtrip import Reads,catalog,check,current_source,state
from verify_web_source_progress import BASE as WEB,WebSourceProbe


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true');parser.add_argument('--apply',action='store_true')
    parser.add_argument('--timed',action='store_true',help='exercise the guarded interval controller')
    parser.add_argument('--book-offset',type=int,choices=range(51),default=15)
    parser.add_argument('--start-page',type=int,choices=range(1,21),default=2)
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if bool(args.saved_session)!=bool(args.lua_command) or args.apply and not args.saved_session:
        parser.error('saved session and private runner required together')
    report=dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0,web_write_posts=0)
    if not args.saved_session:print(json.dumps(report));return 0
    saved=credentials=web=None;phase='credentials'
    try:
        resource.setrlimit(resource.RLIMIT_CORE,(0,0))
        from verify_native_thought_trial import other_pending
        if other_pending():raise ValueError('direct_ui_trial/other_pending')
        store=(NativeDirectIntervalTrialStore if args.timed else NativeDirectUITrialStore)()
        if store.read()[0] is not None:raise ValueError('direct_ui_trial/consumed')
        saved=SessionStore().load();credentials=NativeSessionStore().load(saved['vid'])
        phase='source';sample,_,_=ChapterProbe().inspect(credentials,args.book_offset)
        if sample['expected']['format']!='epub':raise ValueError('direct_ui_trial/format')
        identity=sample['book_id'];native=Reads(credentials,identity)
        before,counts=state(native.request('progress',BASE+'/book/getProgress?'+urlencode(dict(bookId=identity)),credentials=credentials),identity,'native')
        chapters=[row for row in sample['expected']['chapters'] if str(row['uid'])==before['chapter_uid']
            and row.get('free_or_owned') and row.get('wordCount',0)>=200]
        if len(chapters)!=1:raise ValueError('direct_ui_trial/chapter')
        web=WebSourceProbe();web.vid=saved['vid']
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();web.book_id=identity;web.chapter=before['chapter_uid']
        catalog_hash=catalog(web,identity,before['chapter_uid'],before['chapter_idx'])
        raw=current_source(sample,before['chapter_uid'],credentials,web)
        if catalog(web,identity,before['chapter_uid'],before['chapter_idx'])!=catalog_hash:raise ValueError('direct_ui_trial/catalog')
        shelf=state_hash(native.request('shelf',BASE+'/shelf/sync',credentials=credentials))
        web_shelf=state_hash(web.request('shelf',WEB+'/web/shelf/sync'))
        guest,_=guest_token(native.request('feature',BASE+'/feature?synckey=0',credentials=credentials))
        plan=dict(protocol=PROTOCOL,owner_sha256=digest(saved['vid']),source_sha256=hashlib.sha256(raw).hexdigest(),
            catalog_sha256=catalog_hash,grant_sha256=digest(credentials),shelf_sha256=shelf,baseline=before,target=deepcopy(before),
            counts=counts,version=sample['expected']['version'],chapter_progress=None)
        check(web,native,credentials,identity,before,counts,shelf,web_shelf)
        payload=dict(credentials=credentials,book_id=identity,uid=before['chapter_uid'],book_version=plan['version'],
            source_sha256=plan['source_sha256'],search_token=search_token(raw),web_cookies=saved['cookies'],start_page=args.start_page,
            trial=dict(plan=plan,armed=args.apply,timed=args.timed,natural=args.timed and args.apply,
                guest=guest,time_zone=local_zone(),rpc_token=secrets.token_hex(16)))
        def current():
            if digest(NativeSessionStore().load(saved['vid']))!=plan['grant_sha256'] or SessionStore().load()['vid']!=saved['vid']:
                raise ValueError('direct_ui_trial/grant')
        def before_write(seq,bound):
            latest=current_source(sample,before['chapter_uid'],credentials,web)
            if hashlib.sha256(latest).hexdigest()!=bound['source_sha256'] \
                    or catalog(web,identity,before['chapter_uid'],before['chapter_idx'])!=bound['catalog_sha256']:
                raise ValueError('direct_ui_trial/source')
            check(web,native,credentials,identity,bound['baseline' if seq==1 else 'target'],counts,shelf,web_shelf)
        def after_write(seq,bound):
            wanted=bound['target' if seq==1 else 'baseline'];prior=bound['baseline' if seq==1 else 'target']
            for attempt in range(4):
                if check(web,native,credentials,identity,wanted,counts,shelf,web_shelf,previous=prior):return
                if attempt<3:time.sleep(1)
            raise ValueError('direct_ui_trial/readback_pending')
        phase='reader';execute(payload,args.lua_command,store,raw,report,current=current,before=before_write,after=after_write)
        phase='final';check(web,native,credentials,identity,before,counts,shelf,web_shelf);web.verify_account()
        report.update(cloud_and_shelf_restored=True,reading_counts_unchanged=True)
        if args.timed:report.update(timed_controller=True,natural_timer=args.apply,baseline_seeded_from_read_only_preview=True)
    except (Exception,KeyboardInterrupt) as error:
        report.update(result='UNVERIFIED',phase=phase)
        if isinstance(error,ValueError) and str(error).startswith('direct_ui_trial/'):
            report['reason']=str(error)
    finally:
        if web:web.close()
        if saved:saved.clear()
        if credentials:credentials.clear()
    print(json.dumps(report))
    return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
