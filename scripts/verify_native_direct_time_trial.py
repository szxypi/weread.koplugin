#!/usr/bin/env python3
"""One supervised native-chapter current-day time trial.

Offline by default. --saved-session rehearses with dispatch denied. --apply
uses one permanent Keychain claim and never retries an uncertain write.
"""
import argparse
from copy import deepcopy
import hashlib
import json
import re
import resource
import subprocess
import time
from urllib.parse import urlencode

from native_direct_time_trial_contract import day,validate_claim,validate_selection
from native_direct_time_trial_store import Intent
from native_trial_pipe import Frames,reply,stop,write_initial
from readtime_statistics import compare,validate as validate_statistics
from readtime_upload_model import confirmed,guest_token
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from shelf_flag_change_contract import state_hash
from verify_cb_fixture_web_time import NativeRead
from verify_cb_native_time_guarded_dry import trusted_command as base_command
from verify_eink_login import BASE
from verify_native_chapter_package import ChapterProbe
from verify_native_time_capture import full_point
from verify_native_thought_trial import other_pending
from verify_native_txt_position import Native
from verify_native_statistics import period
from verify_readtime_upload import counters,expected_statistics
from verify_web_source_progress import BASE as WEB,WebSourceProbe


def trusted_command(armed):
    command=base_command();old='scripts/run_cb_native_time_guarded_dry.py'
    if command.count(old)!=1 or command.count('--source')!=1:raise ValueError('direct_time/command')
    command[command.index(old)]='scripts/run_native_direct_time_trial.py'
    index=command.index('--source');del command[index:index+2]
    command+=['--width','1264','--height','1680','--dpi','300']
    if armed:command.append('--armed')
    return command


def web_cookies(probe,owner):
    values={cookie.name:cookie.value for cookie in probe.cookies if cookie.name in {'wr_vid','wr_skey','wr_rt','wr_ql','wr_pf'}}
    if values.get('wr_vid')!=owner or not values.get('wr_skey'):raise ValueError('direct_time/web_session')
    return values


def snapshot(grant,book,web):
    api=NativeRead(grant,book);native_raw=api.progress();stats=api.stats()
    web.book_id=book;web_raw=web.request('progress_after',WEB+'/web/book/getProgress?'+urlencode({'bookId':book}))
    shelf=ChapterProbe().request('shelf',BASE+'/shelf/sync',credentials=grant)
    month=str(stats['baseTime'])
    return dict(native_point=full_point(native_raw,book,'native'),web_point=full_point(web_raw,book,'web'),
        counts=counters(native_raw,book),shelf_hash=state_hash(shelf),months={month:stats})


def matching_target(before,after,seconds,start,*,allow_added_zero=False):
    if any(before[key]!=after[key] for key in ('native_point','web_point','shelf_hash')):return False
    counts=dict(before['counts']);counts['readingTime']+=seconds
    if after['counts']!=counts:return False
    month=str(period('monthly',start)[0])
    if set(before['months'])!={month} or set(after['months'])!={month}:return False
    validate_statistics(after['months'])
    observed=deepcopy(after['months'])
    if allow_added_zero:
        added=0
        for month,row in observed.items():
            prior=before['months'][month]['readTimes']
            for key,value in list(row['readTimes'].items()):
                if key not in prior and value==0:
                    added+=1
                    if added>2:return False
                    del row['readTimes'][key]
    for delta in (0,1):
        expected=expected_statistics(before['months'][month],start,seconds,time_zone='+08:00')
        expected['readDays']=before['months'][month]['readDays']+delta
        if compare({month:expected},observed) is not None:return True
    return False


def run(*,apply=False,intent=None,predecessor=None):
    if type(apply) is not bool:raise ValueError('direct_time/mode')
    report=dict(result='UNVERIFIED',phase='start',account_data_posts=0,authentication_posts=0,
        dispatch_may_have_occurred=False,private_data_in_report=False)
    child=web=saved=grant=None;receipt=None;awaiting=None
    try:
        intent=Intent() if intent is None else intent
        if intent.read()!=(None,None) or other_pending():raise ValueError('direct_time/pending')
        command=trusted_command(apply)
        saved=SessionStore().load();grant=NativeSessionStore().load(saved['vid'])
        def current():return SessionStore().load()==saved and NativeSessionStore().load(saved['vid'])==grant
        if grant['vid']!=saved['vid'] or not current():raise ValueError('direct_time/session')
        if predecessor is not None:predecessor.check(grant)
        report['phase']='sample';probe=ChapterProbe();sample,chapter,source=probe.inspect(grant,1)
        book=sample['book_id'];uid=str(chapter['uid']);version=sample['expected']['version']
        if sample['expected']['format']!='epub' or not source['html'] or type(version) is not int or version<=0:
            raise ValueError('direct_time/source')
        expected=dict(book_id=book,uid=uid,version=version,source_sha256=hashlib.sha256(source['source']).hexdigest())
        web=WebSourceProbe();web.vid=saved['vid']
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();cookies=web_cookies(web,saved['vid'])
        initial=snapshot(grant,book,web)
        native=Native(grant,book)
        config=native.request('time_config',BASE+'/config?token=1',credentials=grant)
        feature=native.request('time_feature',BASE+'/feature?synckey=0',credentials=grant)
        guest,_=guest_token(feature);config_token=config.get('token')
        if not isinstance(config_token,str) or not 1<=len(config_token)<=4096:raise ValueError('direct_time/config')
        baseline=dict(initial,guest=guest,config_token=config_token)
        if not current() or web_cookies(web,saved['vid'])!=cookies or snapshot(grant,book,web)!=initial:
            raise ValueError('direct_time/changed')
        stamp=int(time.time());month=period('monthly',stamp)[0]
        if set(initial['months'])!={str(month)} or day(stamp)!=day(stamp+240):raise ValueError('direct_time/clock')
        import secrets
        token=secrets.token_hex(16)
        payload=dict(token=token,armed=apply,credentials=grant,web_cookies=cookies,book_id=book,uid=uid,book_version=version,
            source_sha256=expected['source_sha256'],months=[month])
        report['phase']='runner';child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
        write_initial(child.stdin,payload);frames=Frames(child.stdout,token,timeout=420,max_frame=65536)
        sequence=[];selection=reference=None;seconds=None;runner=None;start=None
        while True:
            kind,event=frames.next()
            if kind=='RESULT':runner=event;break
            awaiting=event;name=event.get('kind');permitted=False
            if name=='ready' and sequence==[]:
                seconds=event.get('seconds');permitted=type(seconds) is int and 5<=seconds<=20 and current()
            elif name=='selection' and sequence==['ready']:
                selection,reference=event.get('selection'),event.get('reference')
                validate_selection(selection,reference,expected,seconds,now=int(time.time()))
                if predecessor is not None:predecessor.check(grant,selection)
                start=selection['protocol_rows'][0]['start_time'];permitted=current()
            elif name=='claim' and sequence==['ready','selection']:
                validate_selection(selection,reference,expected,seconds,now=int(time.time()))
                validate_claim(event,selection,reference,expected,baseline,grant,now=int(time.time()))
                if not current() or web_cookies(web,saved['vid'])!=cookies or snapshot(grant,book,web)!=initial:
                    raise ValueError('direct_time/changed')
                validate_claim(event,selection,reference,expected,baseline,grant,now=int(time.time()))
                if predecessor is not None:predecessor.check(grant,selection,event['record'])
                if apply:
                    plan=dict(selection=deepcopy(selection),record=deepcopy(event['record']),body=deepcopy(event['body']),
                        baseline=deepcopy(initial))
                    receipt=intent.claim(plan);report.update(account_data_posts=None,dispatch_may_have_occurred=True)
                    permitted=True
                else:permitted=False
            elif name=='ack' and sequence==['ready','selection','claim'] and apply:
                if event.get('status')!=200 or not confirmed(event.get('response')) or not current():
                    raise ValueError('direct_time/receipt')
                receipt=intent.advance(receipt,'acknowledged');report['account_data_posts']=1;permitted=True
            else:raise ValueError('direct_time/order')
            sequence.append(name);reply(child.stdin,dict(kind=name,ok=permitted));awaiting=None
            if name!='claim' and not permitted:raise ValueError('direct_time/denied')
        if child.wait(timeout=15)!=0 or not isinstance(runner,dict) or runner.get('profile_removed') is not True:
            raise ValueError('direct_time/runner')
        if not apply:
            if runner.get('result')!='DRY_BLOCKED' or sequence!=['ready','selection','claim'] or intent.read()!=(None,None):
                raise ValueError('direct_time/dry')
            report.update(result='DIRECT_NATIVE_TIME_DRY_VERIFIED',phase='complete',profile_removed=True)
        else:
            if runner.get('result')!='ACKNOWLEDGED' or sequence!=['ready','selection','claim','ack'] or receipt is None:
                raise ValueError('direct_time/runner')
            report['phase']='readback';previous=None;stable=0
            for attempt in range(4):
                if attempt:time.sleep(2)
                after=snapshot(grant,book,web)
                if matching_target(initial,after,seconds,start,allow_added_zero=True):
                    stable=stable+1 if after==previous else 1;previous=after
                    if stable>=2:break
                else:stable=0;previous=None
            if stable<2 or not current():raise ValueError('direct_time/readback')
            receipt=intent.advance(receipt,'verified')
            report.update(result='DIRECT_NATIVE_TIME_ACCOUNTING_VERIFIED',phase='complete',profile_removed=True,
                seconds=seconds,independent_readbacks=stable,position_unchanged=True,shelf_unchanged=True,
                one_shot_record_retained=True)
    except (Exception,KeyboardInterrupt) as error:
        if isinstance(error,ValueError) and re.fullmatch('direct_time/[a-z_]+',str(error)):report['reason']=str(error)
        if child is not None and child.poll() is None and awaiting is not None:
            try:reply(child.stdin,dict(kind=awaiting.get('kind'),ok=False))
            except Exception:pass
    finally:
        if child is not None:stop(child)
        if web:web.close()
        for value in (saved,grant):
            if isinstance(value,dict):value.clear()
    return report


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--apply',action='store_true');args=parser.parse_args(argv)
    if args.apply and not args.saved_session:parser.error('--apply requires --saved-session')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));report=run(apply=args.apply);print(json.dumps(report))
    return int(report['result'] not in ('DIRECT_NATIVE_TIME_DRY_VERIFIED','DIRECT_NATIVE_TIME_ACCOUNTING_VERIFIED'))


if __name__=='__main__':raise SystemExit(main())
