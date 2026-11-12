#!/usr/bin/env python3
"""Bounded same-point TXT enter/read experiment; no automatic replay/renewal."""
import argparse
from datetime import datetime,timezone
import hashlib
import json
import resource
from urllib.parse import urlencode
from secure_weread_session import SessionStore
from secure_txt_full_summary import TxtFullSummaryStore
from verify_txt_cloud_position import Probe as ReadProbe
from verify_reader_progress import project,find_node
from verify_position_roundtrip import same_position,acknowledged,validate_payload
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE
from shelf_flag_change_contract import state_hash
from txt_full_summary import prepare,payload,digest,PROTOCOL,receipt_summary

URL=BASE+'/web/book/read'


class Probe(ReadProbe):
    def __init__(self):super().__init__();self.pending=None;self.posts=0;self.wire=None
    def guard(self,stage,url,body):
        if stage in ('write_enter','write_same'):
            if not self.authenticated or not any(c.name=='wr_vid' and c.value==self.vid for c in self.cookies) or url!=URL or self.pending!=(stage,digest(body)) or self.posts not in (1,2):raise ValueError('txt_full/scope')
            validate_payload(self.wire,stage,body);return
        return super().guard(stage,url,body)
    def send(self,stage,body,claim):
        if self.pending or stage!=('write_enter' if self.posts==0 else 'write_same') or self.posts>=2:raise ValueError('txt_full/replay')
        validate_payload(self.wire,stage,body);claim();self.posts+=1;self.pending=(stage,digest(body))
        try:return self.request(stage,URL,body)
        finally:self.pending=None
    def exact(self,baseline,shelf_hash):
        current=self.request('progress_after',BASE+'/web/book/getProgress?'+urlencode(dict(bookId=self.book_id)))
        shelf=self.request('shelf',BASE+'/web/shelf/sync')
        if not same_position(project(current,self.book_id),baseline) or find_node(current,self.book_id).get('summary')!=baseline['summary'] or state_hash(shelf)!=shelf_hash:raise ValueError('txt_full/readback')


def run(web,session,saved,intent,report,apply=False):
    if not web.find_sample(limit=16):raise ValueError('txt_full/no_sample')
    plan=web.inspect_plan();web.wire=prepare(plan)
    shelf_hash=state_hash(web.request('shelf',BASE+'/web/shelf/sync'))
    web.verify_account();save_refreshed_web_session(session,saved,web);saved=session.load();grant=digest(saved)
    static=dict(point=web.wire['baseline'],ps=web.wire['context']['psvts'],pc=web.wire['pclts'],token=web.wire['context'].get('token'))
    bound=dict(protocol=PROTOCOL,owner_sha256=digest(saved['vid']),grant_sha256=grant,source_sha256=hashlib.sha256(web.sample['plain'].encode()).hexdigest(),
        baseline_sha256=digest(web.wire['baseline']),shelf_sha256=shelf_hash,request_sha256=digest(static))
    report.update(result='FULL_SUMMARY_SAME_POINT_PLAN_VERIFIED',summary_scalars=len(web.wire['baseline']['summary']),planned_posts=2,planned_read_seconds=0)
    web.exact(web.wire['baseline'],shelf_hash)
    if not apply:return
    receipt=intent.reserve(bound)
    try:
        for stage,before,pending,after in (('write_enter','prepared','enter_pending','enter_verified'),('write_same','enter_verified','same_pending','retired')):
            if digest(session.load())!=grant:raise ValueError('txt_full/grant_changed')
            web.exact(web.wire['baseline'],shelf_hash)
            body=payload(web.wire,stage)
            def claim():
                nonlocal receipt
                if digest(session.load())!=grant:raise ValueError('txt_full/grant_changed')
                receipt=intent.advance(receipt,before,pending)
            previous_posts=web.posts
            try:ack=web.send(stage,body,claim)
            except Exception:
                if web.posts>previous_posts:
                    try:
                        web.exact(web.wire['baseline'],shelf_hash);report[stage+'_original_readback']=True
                    except Exception:report[stage+'_original_readback']=False
                raise
            report[stage+'_receipt']=receipt_summary(ack)
            # Read independently even when the response has an unknown business receipt.
            web.exact(web.wire['baseline'],shelf_hash)
            report[stage+'_original_readback']=True
            if not acknowledged(ack):raise ValueError('txt_full/unknown_ack')
            report[stage+'_acknowledged']=True
            receipt=intent.advance(receipt,pending,after)
        web.exact(web.wire['baseline'],shelf_hash)
        report.update(result='TXT_FULL_SUMMARY_SAME_POINT_VERIFIED',original_point_summary_and_visible_shelf_unchanged=True,intent_phase='retired')
    except Exception:
        state,_r=intent.read()
        if state and state['phase']=='prepared':intent.advance(receipt,'prepared','aborted')
        raise


def resolve(web,intent,report):
    state,receipt=intent.read()
    if not state or state['phase'] not in ('enter_pending','same_pending'):raise ValueError('txt_full/no_pending')
    bound=state['plan']
    if digest(web.vid)!=bound['owner_sha256']:raise ValueError('txt_full/owner')
    if not web.find_sample(limit=16):raise ValueError('txt_full/no_sample')
    plan=prepare(web.inspect_plan())
    if (hashlib.sha256(web.sample['plain'].encode()).hexdigest()!=bound['source_sha256']
            or digest(plan['baseline'])!=bound['baseline_sha256']):raise ValueError('txt_full/baseline_changed')
    for _i in range(2):web.exact(plan['baseline'],bound['shelf_sha256'])
    phase='closed_enter_unverified' if state['phase']=='enter_pending' else 'closed_same_unverified'
    intent.advance(receipt,state['phase'],phase)
    report.update(result='TXT_UNKNOWN_RECEIPT_CLOSED_ORIGINAL_BINDINGS_VERIFIED',original_point_summary_and_visible_shelf_unchanged=True,
        prior_protocol_success_claimed=False,intent_phase=phase)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');parser.add_argument('--apply',action='store_true');parser.add_argument('--resolve',action='store_true');args=parser.parse_args(argv)
    if args.apply and args.resolve or (args.apply or args.resolve) and not args.saved_session:parser.error('--apply requires --saved-session')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,authentication_posts=0,
        private_data_on_regular_disk=False,production_upload_enabled=False)
    web=saved=session=intent=None
    try:
        if args.saved_session:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0))
            from verify_native_thought_trial import other_pending
            if other_pending(exclude_txt_full_summary=args.resolve):raise ValueError('txt_full/other_pending')
            intent=TxtFullSummaryStore()
            if args.apply and intent.read()[0] is not None:raise ValueError('txt_full/consumed')
            session=SessionStore();saved=session.load()
            if saved.get('web',{}).get('renewal_pending'):raise ValueError('txt_full/renewal_pending')
            web=Probe();web.vid=saved['vid']
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account()
            if args.resolve:resolve(web,intent,report)
            else:run(web,session,saved,intent,report,args.apply)
    except Exception:report['result']='UNVERIFIED'
    finally:
        if web:
            report['account_data_posts']=web.posts
            if web.authenticated:
                try:web.verify_account();save_refreshed_web_session(session,session.load(),web)
                except Exception:report['result']='UNVERIFIED'
            report['stages']=[{key:row[key] for key in ('stage','status','api_code') if key in row} for row in web.report['stages']]
            web.sample=None;web.close()
        if intent:
            try:
                state,_r=intent.read();report['intent_phase']=state['phase'] if state else 'absent'
            except Exception:report['intent_phase']='unverified'
        if saved:saved.clear()
    print(json.dumps(report,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
