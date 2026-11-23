#!/usr/bin/env python3
"""One time-only probe on an unstarted ordinary EPUB book.

Offline by default. --saved-session performs read-only preparation; --apply
sends at most one independently validated, two-second report, under a separate
permanent Keychain claim. No progress/position request is sent. The chosen
existing book is intentionally left on the shelf with any resulting two-second
reading-time state so a later first-position experiment can inspect it.
"""
import argparse
from copy import deepcopy
import hashlib
import json
import math
from pathlib import Path
import resource
import secrets
import tempfile
import time
from urllib.parse import urlencode

from cb_unstarted_time_fixture_flow import _baseline,run as time_flow
from native_direct_time_trial_store import Intent
from native_initial_position import no_chapter
from native_time_capture_evidence import account_key
from ordinary_unstarted_ui_prior import OrdinaryUnstartedUiTimeStore,PreviousSamples,inspect_book
from readtime_upload_model import batch,confirmed,guest_token,local_zone
from secure_native_session import NativeSessionStore,project_lock
from secure_weread_session import ACCOUNT,MacKeychain,SessionStore
from shelf_flag_change_contract import state_hash
from verify_cb_fixture_web_time import NativeRead
from verify_eink_login import BASE as NATIVE,NativeProbe
from verify_native_chapter_package import ChapterProbe
from verify_native_direct_time_automatic import auto_store
from verify_native_direct_time_successor import PriorGuard,successor_store
from verify_native_direct_time_trial import web_cookies
from verify_native_thought_trial import other_pending
from verify_native_txt_position import Native
from verify_reader_progress import find_node
from verify_readtime_upload import expected_statistics
from verify_web_source_progress import BASE as WEB,WebSourceProbe

SERVICE='org.codex.weread.ordinary-unstarted-time-v1'
COUNTERS=('readingTime','recordReadingTime','ttsTime')


def store():
    path=Path(tempfile.gettempdir())/('codex-ordinary-unstarted-time-'+ACCOUNT+'.lock')
    return Intent(backend=MacKeychain(service=SERVICE,account=ACCOUNT),lock=lambda:project_lock(path))


def projection(raw,book):
    point=no_chapter(raw,book);node=find_node(raw,book)
    values={}
    for key in COUNTERS:
        item=node.get(key)
        if type(item) is not int or not 0<=item<=9007199254740991:raise ValueError('unstarted_ordinary/counters')
        values[key]=dict(present=key in node,value=item)
    return dict(state={'kind':'no_chapter','reason':'progress_no_chapter'},presence={
        'index':point['index_present'],'summary':point['summary_present']},projection=point,counters=values)


def normalized_stats(value):
    if not isinstance(value,dict) or set(value)!={'baseTime','readTimes','totalReadTime','readDays'}:
        raise ValueError('unstarted_ordinary/stats')
    result=deepcopy(value);result['readTimes']={k:v for k,v in value['readTimes'].items() if v!=0};return result


def build_body(grant,book,version,start,now,guest,config,r1,r2):
    rows=[dict(start_time=start,duration=2,time_zone='+08:00',book_version=version)]
    if (type(version) is not int or version<=0 or not 0<=now-start-2<=20
            or (start+28800)//86400!=(now+28800)//86400):raise ValueError('unstarted_ordinary/clock')
    return batch(grant,book,rows,guest,config,now,r1,now*1000,r2,current_zone='+08:00')


def run(*,apply=False,ui_sample=False):
    report=dict(result='UNVERIFIED',phase='preflight',account_data_posts=0,authentication_posts=0,
        dispatch_may_have_occurred=False,private_data_in_report=False)
    web=saved=grant=None;state=dict(receipt=None,permit=None,sent=0,expected=None,acknowledged=False)
    try:
        if type(ui_sample) is not bool:raise ValueError('unstarted_ordinary/mode')
        intent=OrdinaryUnstartedUiTimeStore() if ui_sample else store()
        if intent.read()!=(None,None) or other_pending():raise ValueError('unstarted_ordinary/pending')
        saved=SessionStore().load();grant=NativeSessionStore().load(saved['vid'])
        if ui_sample:
            from verify_ordinary_unstarted_initial import store as position_store
            previous=PreviousSamples(store(),position_store())
        else:previous=None
        def current():return SessionStore().load()==saved and NativeSessionStore().load(saved['vid'])==grant
        if not current():raise ValueError('unstarted_ordinary/session')
        guards=[PriorGuard(Intent()),PriorGuard(successor_store()),PriorGuard(auto_store())]
        for guard in guards:guard.check(grant)
        selected=None
        def candidate():
            if ui_sample and selected is not None:sample,chapter,source=inspect_book(grant,selected['book_id'])
            else:sample,chapter,source=ChapterProbe().inspect(grant,2 if ui_sample else 0)
            if sample['expected']['format']!='epub' or not source['html'] or not chapter['free_or_owned']:
                raise ValueError('unstarted_ordinary/source')
            version=sample['expected']['version']
            if type(version) is not int or not 1<=version<=2147483647:raise ValueError('unstarted_ordinary/version')
            chosen=dict(book_id=sample['book_id'],chapter_uid=str(chapter['uid']),version=version,
                source_sha256=hashlib.sha256(source['source']).hexdigest())
            if previous:previous.check(grant,chosen)
            return chosen
        selected=candidate();book=selected['book_id'];version=selected['version']
        web=WebSourceProbe();web.vid=saved['vid']
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();web.book_id=book;cookies=web_cookies(web,saved['vid'])
        if previous:
            from verify_ordinary_unstarted_initial import chapter_index
            from verify_native_direct_roundtrip import catalog,current_source
            web.chapter=selected['chapter_uid']
            index=chapter_index(web,book,selected['chapter_uid']);catalog(web,book,selected['chapter_uid'],index)
            sample,chapter,_=inspect_book(grant,book)
            if (sample['book_id']!=book or str(chapter['uid'])!=selected['chapter_uid']
                    or hashlib.sha256(current_source(sample,selected['chapter_uid'],grant,web)).hexdigest()!=selected['source_sha256']
                    or candidate()!=selected):raise ValueError('unstarted_ordinary/source')
        api=NativeRead(grant,book);native=Native(grant,book)
        native_shelf=state_hash(ChapterProbe().request('shelf',NATIVE+'/shelf/sync',credentials=grant))
        web_shelf=state_hash(web.request('shelf',WEB+'/web/shelf/sync'))
        def snapshot():
            first=api.progress();second=web.request('progress_after',WEB+'/web/book/getProgress?'+urlencode({'bookId':book}))
            return dict(native=projection(first,book),web=projection(second,book))
        def stats():return normalized_stats(api.stats())
        def authority(permit=None):
            if not current() or web_cookies(web,saved['vid'])!=cookies:return False
            for guard in guards:guard.check(grant)
            if previous:previous.check(grant,selected)
            if state_hash(ChapterProbe().request('shelf',NATIVE+'/shelf/sync',credentials=grant))!=native_shelf:return False
            if state_hash(web.request('shelf',WEB+'/web/shelf/sync'))!=web_shelf:return False
            value,raw=intent.read()
            if permit is None:return value is None and raw is None
            return (permit==state['permit'] and raw==state['receipt'] and value is not None
                and value['phase'] in ('claimed','acknowledged'))
        config=native.request('unstarted_config',NATIVE+'/config?token=1',credentials=grant)
        feature=native.request('unstarted_feature',NATIVE+'/feature?synckey=0',credentials=grant)
        guest,_=guest_token(feature);token=config.get('token')
        if not isinstance(token,str) or not token or len(token)>4096:raise ValueError('unstarted_ordinary/config')
        def prepare(before,initial):
            if candidate()!=selected or local_zone()!='+08:00':raise ValueError('unstarted_ordinary/source')
            wall=time.time();mono=time.monotonic();start=math.ceil(wall)
            if int((wall+60+28800)//86400)!=int((wall+28800)//86400):raise ValueError('unstarted_ordinary/clock')
            time.sleep(max(0,start+2-wall)+.01)
            if not 2<=time.monotonic()-mono<=4 or not 0<=time.time()-(start+2)<2:
                raise ValueError('unstarted_ordinary/clock')
            stamp=int(time.time());interval=dict(protocol_rows=[dict(start_time=start,duration=2)])
            for guard in guards:guard.check(grant,interval)
            if previous:previous.check(grant,selected,interval)
            if candidate()!=selected:raise ValueError('unstarted_ordinary/source')
            stamp=int(time.time());body=build_body(grant,book,version,start,stamp,guest,token,secrets.randbelow(1000),secrets.randbelow(1000))
            targets=[]
            for delta in (0,1):
                target=normalized_stats(expected_statistics(initial,start,2,time_zone='+08:00'))
                target['readDays']=initial['readDays']+delta;targets.append(target)
            state['selection']=dict(start_time=start,duration=2);state['targets']=targets
            return body,targets
        def reserve(before,initial,body):
            return dict(selection=state['selection'],record=dict(owner=account_key(grant['vid']),source=selected,
                native_shelf=native_shelf,web_shelf=web_shelf),body=body,baseline=dict(pair=before,stats=initial))
        def bind(body):
            inner=body['books'][0];expected=build_body(grant,book,version,state['selection']['start_time'],inner['timestamp'],
                guest,token,inner['random'],body['random'])
            if body!=expected:raise ValueError('unstarted_ordinary/signature')
            state['expected']=deepcopy(expected)
        def claim(plan):
            state['receipt']=intent.claim(plan);state['permit']=state['receipt'];return state['permit']
        def send(body,permit):
            if (state['sent'] or body!=state['expected'] or not authority(permit) or candidate()!=selected
                    or not 0<=time.time()-body['books'][0]['timestamp']<30):raise ValueError('unstarted_ordinary/dispatch')
            state['sent']=1;report.update(account_data_posts=None,dispatch_may_have_occurred=True)
            response=NativeProbe.request(NativeProbe(),'unstarted_time_write',NATIVE+'/book/batchUploadProgress',
                body=body,credentials=grant,timeout=20)
            if confirmed(response):
                report['account_data_posts']=1;state['acknowledged']=True
                state['receipt']=intent.advance(state['receipt'],'acknowledged')
            return response
        if apply:
            report['phase']='dispatch';result=time_flow(snapshot,stats,prepare,reserve,bind,claim,authority,send,sleep=time.sleep)
            report.update(attempted=state['sent'],acknowledged=state['acknowledged'],no_chapter_and_counts_verified=result['no_chapter_and_counts_verified'],
                statistics_verified=result['statistics_verified'])
            if result['result']=='PASS' and authority(state['permit']) and candidate()==selected:
                intent.advance(state['receipt'],'verified')
                report.update(result='UNSTARTED_TIME_VERIFIED',phase='complete',seconds=2,one_shot_record_retained=True)
        else:
            first=_baseline(snapshot());initial=stats()
            if not authority() or _baseline(snapshot())!=first or stats()!=initial:raise ValueError('unstarted_ordinary/changed')
            body,_=prepare(first,initial);bind(body)
            if not authority() or _baseline(snapshot())!=first or stats()!=initial:raise ValueError('unstarted_ordinary/changed')
            if intent.read()!=(None,None):raise ValueError('unstarted_ordinary/pending')
            report.update(result='UNSTARTED_TIME_DRY_VERIFIED',phase='complete',no_chapter_before=True,zero_counts_before=True)
    except (Exception,KeyboardInterrupt):
        pass
    finally:
        if web:web.close()
        if saved:saved.clear()
        if grant:grant.clear()
    return report


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--apply',action='store_true');parser.add_argument('--ui-sample',action='store_true');args=parser.parse_args(argv)
    if args.apply and not args.saved_session:parser.error('apply requires saved session')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));report=run(apply=args.apply,ui_sample=args.ui_sample);print(json.dumps(report))
    return int(report['result'] not in ('UNSTARTED_TIME_DRY_VERIFIED','UNSTARTED_TIME_VERIFIED'))


if __name__=='__main__':raise SystemExit(main())
