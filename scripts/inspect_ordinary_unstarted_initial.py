#!/usr/bin/env python3
"""Fresh, read-only inspection of the verified first-position trial."""
import argparse
import hashlib
import json
import resource
import time
from urllib.parse import urlencode

from native_initial_position import counts
from native_time_capture_evidence import account_key
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from shelf_flag_change_contract import state_hash
from verify_eink_login import BASE as NATIVE
from verify_native_direct_roundtrip import Reads,catalog,current_source,state
from verify_ordinary_unstarted_initial import store as position_store
from verify_ordinary_unstarted_time import store as time_store
from verify_web_source_progress import BASE as WEB,WebSourceProbe


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');args=parser.parse_args(argv)
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));report=dict(result='UNVERIFIED',account_data_posts=0,authentication_posts=0,private_data_in_report=False)
    saved=grant=web=None
    try:
        prior,prior_raw=time_store().read();record,_=position_store().read()
        if not prior or prior['phase']!='verified' or not record or record['phase']!='verified':raise ValueError('initial_inspect/record')
        plan=record['plan'];target=plan['selection']['target'];book=target['book_id'];uid=target['chapter_uid'];index=target['chapter_idx']
        if (hashlib.sha256(prior_raw).hexdigest()!=plan['record']['prior_receipt_sha256']
                or prior['attempt']!=plan['record']['prior_attempt']):raise ValueError('initial_inspect/prior')
        saved=SessionStore().load();grant=NativeSessionStore().load(saved['vid'])
        if prior['plan']['record']['owner']!=account_key(saved['vid']):raise ValueError('initial_inspect/owner')
        web=WebSourceProbe();web.vid=saved['vid']
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();web.book_id=book;web.chapter=uid;native=Reads(grant,book)
        sample=dict(book_id=book,expected=dict(version=plan['record']['version']))
        if (hashlib.sha256(current_source(sample,uid,grant,web)).hexdigest()!=plan['selection']['source_sha256']
                or catalog(web,book,uid,index)!=plan['selection']['catalog_sha256']):raise ValueError('initial_inspect/source')
        def snapshot():
            n=native.request('progress',NATIVE+'/book/getProgress?'+urlencode({'bookId':book}),credentials=grant)
            w=web.request('progress_after',WEB+'/web/book/getProgress?'+urlencode({'bookId':book}))
            npoint,_=state(n,book,'native');wpoint,_=state(w,book,'web')
            return dict(native=npoint,web=wpoint,native_counts=counts(n,book),web_counts=counts(w,book),
                native_shelf=state_hash(native.request('shelf',NATIVE+'/shelf/sync',credentials=grant)),
                web_shelf=state_hash(web.request('shelf',WEB+'/web/shelf/sync')))
        first=snapshot();time.sleep(2);second=snapshot()
        expected=dict(readingTime=2,recordReadingTime=0,ttsTime=0)
        if (first!=second or second['native']!=target or second['web']!=target or second['native_counts']!=expected
                or second['web_counts']!=expected or second['native_shelf']!=plan['record']['native_shelf']
                or second['web_shelf']!=plan['record']['web_shelf'] or SessionStore().load()!=saved
                or NativeSessionStore().load(saved['vid'])!=grant or time_store().read()[1]!=prior_raw):
            raise ValueError('initial_inspect/changed')
        report.update(result='UNSTARTED_INITIAL_INDEPENDENTLY_VERIFIED',independent_readbacks=2,
            position_matches=True,reading_time_preserved=2,source_and_shelf_unchanged=True,prior_record_unchanged=True)
    except (Exception,KeyboardInterrupt):pass
    finally:
        if web:web.close()
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(report));return int(report['result']!='UNSTARTED_INITIAL_INDEPENDENTLY_VERIFIED')


if __name__=='__main__':raise SystemExit(main())
