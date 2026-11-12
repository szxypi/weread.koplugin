#!/usr/bin/env python3
"""One native TXT adjacent+restore trial; no retries, Web writes or time rows."""
import argparse
from datetime import datetime,timezone
import hashlib
import json
import resource
import secrets
import time
from urllib.parse import urlencode
from secure_weread_session import SessionStore
from secure_native_session import NativeSessionStore
from secure_native_txt_roundtrip import NativeTxtRoundtripStore,POINT_FIELDS
from verify_native_txt_position import Native,Source,inspect
from verify_native_txt_same_point import exact
from verify_translation_preflight import save_refreshed_web_session
from verify_eink_login import NativeProbe,BASE
from verify_web_source_progress import BASE as WEB
from verify_position_roundtrip import same_position
from verify_reader_progress import find_node,project
from native_txt_summary import prepare as slide
from native_txt_read_model import body
from readtime_upload_model import confirmed,local_zone,integer
from shelf_flag_change_contract import state_hash
from txt_full_summary import digest,receipt_summary


class Probe(Native):
    max_reads=24
    def __init__(self,credentials,identity,opener=None,*,restore_only=False):
        super().__init__(credentials,identity,opener);self.posts=0;self.pending=None;self.claim=None
        self.next='native_txt_restore' if restore_only else 'native_txt_advance'
    def request(self,stage,url,body=None,credentials=None,timeout=15):
        if body is None:return super().request(stage,url,credentials=credentials,timeout=timeout)
        if (stage!=self.next or stage not in ('native_txt_advance','native_txt_restore') or url!=BASE+'/book/read'
                or credentials!=self.credentials or self.posts>=2 or self.pending!=digest(body) or not self.claim
                or body.get('readingTime')!=0 or body.get('hours')!=[] or not 0<=time.time()-body['timestamp']<=30):raise ValueError('txt_roundtrip/dispatch')
        self.claim();self.posts+=1;self.next='native_txt_restore' if stage=='native_txt_advance' else None
        return NativeProbe.request(self,stage,url,body,credentials,timeout)


def compact(point):return {key:point[key] for key in POINT_FIELDS}
def source_hash(web):return hashlib.sha256(web.sample['plain'].encode()).hexdigest()
def catalog_hash(web):
    record=web.sample['record'];book=record.get('book',{})
    fields=('bookId','format','bookVersion','version')
    return digest(dict(record={k:record[k] for k in fields if k in record},book={k:book[k] for k in fields if k in book},chapters=web.sample['chapters']))


def make_plan(web,native,credentials,report):
    source=web.inspect_plan();observation=inspect(web,native,credentials,source,report);candidate=slide(web.sample['plain'],source)
    return dict(protocol=NativeTxtRoundtripStore.protocol,owner_sha256=digest(web.vid),source_sha256=source_hash(web),catalog_sha256=catalog_hash(web),
        grant_sha256=digest(credentials),shelf_sha256=state_hash(web.request('shelf',WEB+'/web/shelf/sync')),
        baseline=compact(candidate['baseline']),target=compact(candidate['target']),counts=observation['counts'],version=observation['version'],
        chapter_progress=find_node(observation['native_progress'],web.book_id).get('chapterProgress')),observation['guest']


def check(web,native,credentials,plan,expected,*,refresh=False):
    if digest(web.vid)!=plan['owner_sha256'] or web.book_id!=plan['baseline']['book_id']:raise ValueError('txt_roundtrip/owner')
    if refresh:
        if not web.find_sample(book_id=web.book_id):raise ValueError('txt_roundtrip/source')
        current=web.inspect_plan()['baseline']
        if not same_position(current,expected) or current['summary']!=expected['summary']:raise ValueError('txt_roundtrip/position')
        metadata=native.request('native_txt_roundtrip_metadata',BASE+'/book/info?'+urlencode(dict(bookId=web.book_id)),credentials=credentials)
        if (str(metadata.get('bookId'))!=web.book_id or any(type(metadata[k]) is not int or metadata[k]!=plan['version'] for k in ('version','bookVersion') if k in metadata)
                or not any(k in metadata for k in ('version','bookVersion'))):raise ValueError('txt_roundtrip/version')
    if source_hash(web)!=plan['source_sha256'] or catalog_hash(web)!=plan['catalog_sha256']:raise ValueError('txt_roundtrip/source')
    exact(web,native,credentials,{'baseline':expected},plan['counts'],plan['shelf_sha256'])


def snapshot(web,native,credentials,plan,expected,before):
    """Both transports must show one whole known state, with unchanged counts."""
    if source_hash(web)!=plan['source_sha256'] or catalog_hash(web)!=plan['catalog_sha256']:raise ValueError('txt_roundtrip/source')
    raw_native=native.request('native_txt_settle',BASE+'/book/getProgress?'+urlencode(dict(bookId=web.book_id)),credentials=credentials)
    raw_web=web.request('progress_after',WEB+'/web/book/getProgress?'+urlencode(dict(bookId=web.book_id)))
    counts={key:find_node(raw_native,web.book_id).get(key) for key in plan['counts']}
    if any(not integer(n,0,2**53-1) for n in counts.values()) or counts!=plan['counts']:raise ValueError('native_txt/time_changed')
    ready=[]
    for kind,raw in (('native',raw_native),('web',raw_web)):
        current=project(raw,web.book_id,kind);summary=find_node(raw,web.book_id).get('summary')
        matches=[same_position(current,candidate) and summary==candidate['summary'] for candidate in (expected,before)]
        if not any(matches):raise ValueError('txt_roundtrip/unknown_readback')
        ready.append(matches[0])
    if state_hash(web.request('shelf',WEB+'/web/shelf/sync'))!=plan['shelf_sha256']:raise ValueError('native_txt/shelf_changed')
    return all(ready)


def settle(web,native,credentials,plan,expected,before,report,stage,acknowledged):
    """At most four read-only observations; never repeat the preceding POST."""
    for attempt in range(1,5 if acknowledged else 2):
        report.setdefault('readback_attempts',{})[stage]=attempt
        if snapshot(web,native,credentials,plan,expected,before):return
        if not acknowledged or attempt==4:break
        time.sleep(1)
    raise ValueError('txt_roundtrip/readback_pending')


def dispatch(web,native,credentials,session,store,receipt,plan,guest,stage,before,expected,report):
    check(web,native,credentials,plan,expected,refresh=True)
    target=plan['target'] if stage=='native_txt_advance' else plan['baseline']
    value=body(credentials,target,plan['version'],guest,int(time.time()),secrets.randbelow(1000),local_zone(),plan['chapter_progress'])
    def claim():
        nonlocal receipt
        if (digest(NativeSessionStore().load(web.vid))!=plan['grant_sha256']
                or digest(session.load()['vid'])!=plan['owner_sha256']):raise ValueError('txt_roundtrip/grant')
        receipt=store.advance(receipt,before,'advance_pending' if stage=='native_txt_advance' else 'restore_pending')
    native.claim=claim;native.pending=digest(value)
    ack=native.request(stage,BASE+'/book/read',body=value,credentials=credentials)
    report.setdefault('receipts',[]).append(dict(step='advance' if stage=='native_txt_advance' else 'restore',**receipt_summary(ack)))
    acknowledged=confirmed(ack)
    if acknowledged:
        pending='advance_pending' if stage=='native_txt_advance' else 'restore_pending'
        ack_phase='advance_acknowledged' if stage=='native_txt_advance' else 'restore_acknowledged_unverified_advance' if before=='advance_pending' else 'restore_acknowledged'
        receipt=store.advance(receipt,pending,ack_phase)
    settle(web,native,credentials,plan,target,expected,report,stage,acknowledged)
    report['target_readback' if stage=='native_txt_advance' else 'original_readback']=True
    if not acknowledged:raise ValueError('txt_roundtrip/ack')
    return store.advance(receipt,'advance_acknowledged','advance_verified') if stage=='native_txt_advance' else receipt


def run(web,native,credentials,session,saved,store,report,*,apply=False,restore_only=False,resolving=False,planner=None,summary_method='slide_observed_window_once'):
    if restore_only or resolving:
        state,receipt=store.read()
        if not state or not store.pending():raise ValueError('txt_roundtrip/no_pending')
        plan=state['plan']
        if digest(web.vid)!=plan['owner_sha256']:raise ValueError('txt_roundtrip/owner')
        if resolving:
            for _i in range(2):check(web,native,credentials,plan,plan['baseline'],refresh=True)
            after={'prepared':'aborted','advance_pending':'closed_advance_unverified','advance_acknowledged':'closed_advance_unverified','advance_verified':'closed_advance_unverified',
                'restore_pending':'closed_restore_unverified','restore_acknowledged':'retired','restore_acknowledged_unverified_advance':'restored_advance_unverified'}[state['phase']]
            store.advance(receipt,state['phase'],after)
            report.update(result='NATIVE_TXT_ORIGINAL_STATE_RESOLVED_WITHOUT_REPLAY',prior_roundtrip_success_claimed=after=='retired');return
        if state['phase'] not in ('advance_pending','advance_acknowledged','advance_verified'):raise ValueError('txt_roundtrip/restore_slot')
        current=web.inspect_plan();observation=inspect(web,native,credentials,current,report)
        if observation['version']!=plan['version']:raise ValueError('txt_roundtrip/version')
        guest=observation['guest'];check(web,native,credentials,plan,plan['target'])
        receipt=dispatch(web,native,credentials,session,store,receipt,plan,guest,'native_txt_restore',state['phase'],plan['target'],report)
        known=state['phase']!='advance_pending'
        store.advance(receipt,'restore_acknowledged' if known else 'restore_acknowledged_unverified_advance','retired' if known else 'restored_advance_unverified')
        report.update(result='NATIVE_TXT_ORIGINAL_RESTORED_ONCE',original_restoration_verified=True,prior_advance_success_claimed=known);return
    plan,guest=(planner or make_plan)(web,native,credentials,report)
    web.verify_account();save_refreshed_web_session(session,saved,web)
    if digest(NativeSessionStore().load(web.vid))!=plan['grant_sha256']:raise ValueError('txt_roundtrip/grant')
    check(web,native,credentials,plan,plan['baseline'],refresh=True)
    report.update(result='NATIVE_TXT_ADJACENT_RESTORE_PLAN_VERIFIED',planned_posts=2,planned_read_seconds=0,full_summary_scalars=len(plan['baseline']['summary']),
        summary_method=summary_method,internal_whitespace_preserved=True,source_snapshot_only=plan['version']==0)
    if not apply:return
    receipt=store.reserve(plan)
    try:
        receipt=dispatch(web,native,credentials,session,store,receipt,plan,guest,'native_txt_advance','prepared',plan['baseline'],report)
        receipt=dispatch(web,native,credentials,session,store,receipt,plan,guest,'native_txt_restore','advance_verified',plan['target'],report)
        store.advance(receipt,'restore_acknowledged','retired')
        report.update(result='NATIVE_TXT_ADJACENT_RESTORE_PROTOCOL_VERIFIED',original_restoration_verified=True,time_counters_unchanged=True)
    except Exception:
        state,receipt=store.read()
        if state and state['phase']=='prepared':store.advance(receipt,'prepared','aborted')
        raise


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--saved-session',action='store_true')
    modes=p.add_mutually_exclusive_group();modes.add_argument('--apply',action='store_true');modes.add_argument('--restore-only',action='store_true');modes.add_argument('--resolve',action='store_true');a=p.parse_args(argv)
    if (a.apply or a.restore_only or a.resolve) and not a.saved_session:p.error('saved session required')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,authentication_posts=0,web_write_posts=0,historical_time_rows=0,
        production_upload_enabled=False,private_data_on_regular_disk=False)
    session=saved=credentials=web=native=store=None
    try:
        if a.saved_session:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0))
            from verify_native_thought_trial import other_pending
            if other_pending(exclude_native_txt_roundtrip=a.resolve or a.restore_only):raise ValueError('txt_roundtrip/pending')
            store=NativeTxtRoundtripStore();state,_r=store.read()
            if a.apply and state is not None:raise ValueError('txt_roundtrip/consumed')
            session=SessionStore();saved=session.load();credentials=NativeSessionStore().load(saved['vid']);web=Source();web.vid=saved['vid']
            if state and (a.resolve or a.restore_only) and digest(web.vid)!=state['plan']['owner_sha256']:raise ValueError('txt_roundtrip/owner')
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account()
            identity=state['plan']['baseline']['book_id'] if state and (a.resolve or a.restore_only) else None
            if not web.find_sample(book_id=identity,limit=16):raise ValueError('txt_roundtrip/no_sample')
            native=Probe(credentials,web.book_id,restore_only=a.restore_only)
            run(web,native,credentials,session,saved,store,report,apply=a.apply,restore_only=a.restore_only,resolving=a.resolve)
    except (Exception,KeyboardInterrupt) as error:
        report['result']='UNVERIFIED'
        if isinstance(error,ValueError) and str(error) in {'txt_roundtrip/ack','txt_roundtrip/source','txt_roundtrip/version','txt_roundtrip/grant','txt_roundtrip/position','txt_roundtrip/owner','txt_roundtrip/restore_slot','txt_roundtrip/consumed',
                'native_txt/position','native_txt/counters','native_txt/time_changed','native_txt/web_changed','native_txt/shelf_changed',
                'txt_roundtrip/unknown_readback','txt_roundtrip/readback_pending'}:report['reason']=str(error)
        report['exception_type']=type(error).__name__ if type(error).__name__ in ('ValueError','KeyError','TypeError','KeyboardInterrupt') else 'other'
    finally:
        if web:
            if web.authenticated:
                try:web.verify_account();save_refreshed_web_session(session,session.load(),web)
                except Exception:report['result']='UNVERIFIED'
            report['web_stages']=[{k:r[k] for k in ('stage','status','api_code') if k in r} for r in web.report['stages']];web.sample=None;web.close()
        if native:
            report['account_data_posts']=native.posts;report['native_stages']=[{k:r[k] for k in ('stage','status','error_code') if k in r} for r in native.report['stages']]
        if store:
            try:state,_r=store.read();report['intent_phase']=state['phase'] if state else 'absent'
            except Exception:report['intent_phase']='unverified'
        for value in (saved,credentials):
            if value:value.clear()
    print(json.dumps(report,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
