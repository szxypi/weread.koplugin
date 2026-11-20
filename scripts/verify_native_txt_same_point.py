#!/usr/bin/env python3
"""One native same-point position request; no Web write or historical time."""
import argparse
from datetime import datetime,timezone
import hashlib
import json
import resource
import secrets
import time
from urllib.parse import urlencode
from secure_native_session import NativeSessionStore
from secure_native_txt_position import NativeTxtPositionStore
from secure_weread_session import SessionStore
from verify_native_txt_position import Native,Source,inspect,compare
from verify_reader_progress import project,find_node
from verify_position_roundtrip import same_position
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE as WEB
from verify_eink_login import BASE
from readtime_upload_model import confirmed,local_zone
from native_txt_read_model import body
from txt_full_summary import digest,receipt_summary
from shelf_flag_change_contract import state_hash
from verify_txt_zero_time import baseline_digest


class Probe(Native):
    def __init__(self,credentials,identity,opener=None):
        super().__init__(credentials,identity,opener);self.posts=0;self.pending=None;self.claim=None
    def request(self,stage,url,body=None,credentials=None,timeout=15):
        if body is None:return super().request(stage,url,credentials=credentials,timeout=timeout)
        if (stage!='native_txt_same' or url!=BASE+'/book/read' or credentials!=self.credentials or self.posts!=0
                or self.pending!=digest(body) or not self.claim or body.get('readingTime')!=0 or body.get('hours')!=[]
                or not 0<=time.time()-body['timestamp']<=30):raise ValueError('native_txt/dispatch_scope')
        self.claim();self.posts=1
        # Bypass only the read-only route guard after the durable claim.
        from verify_eink_login import NativeProbe
        return NativeProbe.request(self,stage,url,body,credentials,timeout)


def prepare(web,native,credentials,report):
    plan=web.inspect_plan();observation=inspect(web,native,credentials,plan,report)
    shelf_hash=state_hash(web.request('shelf',WEB+'/web/shelf/sync'))
    point=plan['baseline'];progress=find_node(observation['native_progress'],web.book_id)
    value=body(credentials,point,observation['version'],observation['guest'],int(time.time()),secrets.randbelow(1000),local_zone(),progress.get('chapterProgress'))
    return plan,observation,shelf_hash,value


def exact(web,native,credentials,plan,counts,shelf_hash):
    raw=native.request('native_txt_readback',BASE+'/book/getProgress?'+urlencode(dict(bookId=web.book_id)),credentials=credentials)
    _point,current=compare(plan,raw,web.book_id)
    if current!=counts:raise ValueError('native_txt/time_changed')
    raw_web=web.request('progress_after',WEB+'/web/book/getProgress?'+urlencode(dict(bookId=web.book_id)))
    if not same_position(project(raw_web,web.book_id),plan['baseline']) or find_node(raw_web,web.book_id).get('summary')!=plan['baseline']['summary']:raise ValueError('native_txt/web_changed')
    if state_hash(web.request('shelf',WEB+'/web/shelf/sync'))!=shelf_hash:raise ValueError('native_txt/shelf_changed')


def run(web,native,credentials,session,saved,intent,report,apply=False,resolving=False):
    plan,observation,shelf_hash,value=prepare(web,native,credentials,report)
    web.verify_account();save_refreshed_web_session(session,saved,web);saved=session.load();grant=digest(dict(web=saved,native=credentials))
    baseline_hash=baseline_digest(plan['baseline'])
    scope=dict(protocol=intent.protocol,owner_sha256=digest(web.vid),source_sha256=hashlib.sha256(web.sample['plain'].encode()).hexdigest(),
        baseline_sha256=baseline_hash,grant_sha256=grant,shelf_sha256=digest(dict(shelf=shelf_hash,counts=observation['counts'])),request_sha256=digest(value))
    if resolving:
        state,receipt=intent.read()
        if not state or state['phase']!='same_pending' or any(scope[k]!=state['plan'][k] for k in ('owner_sha256','source_sha256','baseline_sha256','shelf_sha256')):raise ValueError('native_txt/resolution')
        for _i in range(2):exact(web,native,credentials,plan,observation['counts'],shelf_hash)
        intent.advance(receipt,'same_pending','closed_same_unverified')
        report.update(result='NATIVE_TXT_UNKNOWN_CLOSED_ORIGINAL_BINDINGS_VERIFIED',prior_protocol_success_claimed=False);return
    report.update(result='NATIVE_TXT_SAME_POINT_PLAN_VERIFIED',planned_posts=1,planned_read_seconds=0,summary_scalars=len(value['summary']),
        version_positive=observation['version']>0,source_snapshot_only=observation['version']==0)
    exact(web,native,credentials,plan,observation['counts'],shelf_hash)
    if not apply:return
    receipt=intent.reserve(scope)
    def claim():
        nonlocal receipt
        if digest(dict(web=session.load(),native=NativeSessionStore().load(web.vid)))!=grant:raise ValueError('native_txt/grant_changed')
        receipt=intent.advance(receipt,'prepared','same_pending')
    native.claim=claim;native.pending=digest(value)
    try:
        exact(web,native,credentials,plan,observation['counts'],shelf_hash)
        try:ack=native.request('native_txt_same',BASE+'/book/read',body=value,credentials=credentials)
        except Exception:
            if native.posts:
                try:exact(web,native,credentials,plan,observation['counts'],shelf_hash);report['original_readback']=True
                except Exception:report['original_readback']=False
            raise
        report['receipt']=receipt_summary(ack);exact(web,native,credentials,plan,observation['counts'],shelf_hash);report['original_readback']=True
        if not confirmed(ack):raise ValueError('native_txt/ack')
        intent.advance(receipt,'same_pending','retired');report.update(result='NATIVE_TXT_SAME_POINT_PROTOCOL_VERIFIED',explicit_success_receipt=True,time_counters_unchanged=True)
    except Exception:
        state,_r=intent.read()
        if state['phase']=='prepared':intent.advance(receipt,'prepared','aborted')
        raise


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--saved-session',action='store_true');m=p.add_mutually_exclusive_group();m.add_argument('--apply',action='store_true');m.add_argument('--resolve',action='store_true');a=p.parse_args(argv)
    if (a.apply or a.resolve) and not a.saved_session:p.error('saved session required')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,authentication_posts=0,web_write_posts=0,
        historical_time_rows=0,private_data_on_regular_disk=False,production_upload_enabled=False)
    session=saved=credentials=web=native=intent=None
    try:
        if a.saved_session:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0))
            from verify_native_thought_trial import other_pending
            if other_pending(exclude_native_txt=a.resolve):raise ValueError('native_txt/pending')
            intent=NativeTxtPositionStore()
            if a.apply and intent.read()[0] is not None:raise ValueError('native_txt/consumed')
            session=SessionStore();saved=session.load();credentials=NativeSessionStore().load(saved['vid']);web=Source();web.vid=saved['vid']
            for k,v in saved['cookies'].items():web.set_cookie(k,v)
            web.verify_account()
            if not web.find_sample(limit=16):raise ValueError('native_txt/no_sample')
            native=Probe(credentials,web.book_id);run(web,native,credentials,session,saved,intent,report,a.apply,a.resolve)
    except Exception as error:
        report['result']='UNVERIFIED'
        if isinstance(error,ValueError) and str(error) in {'native_txt/ack','native_txt/time_changed','native_txt/web_changed','native_txt/shelf_changed','native_txt/grant_changed'}:report['reason']=str(error)
    finally:
        if web:
            if web.authenticated:
                try:web.verify_account();save_refreshed_web_session(session,session.load(),web)
                except Exception:report['result']='UNVERIFIED'
            report['web_stages']=[{k:r[k] for k in ('stage','status','api_code') if k in r} for r in web.report['stages']];web.sample=None;web.close()
        if native:
            report['account_data_posts']=native.posts;report['native_stages']=[{k:r[k] for k in ('stage','status','error_code') if k in r} for r in native.report['stages']]
        if intent:
            try:state,_r=intent.read();report['intent_phase']=state['phase'] if state else 'absent'
            except Exception:report['intent_phase']='unverified'
        for value in (saved,credentials):
            if value:value.clear()
    print(json.dumps(report,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
