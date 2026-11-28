#!/usr/bin/env python3
"""One same-point rt=0 request with live config; no enter, retry or renewal."""
import argparse
from datetime import datetime,timezone
import hashlib
import json
import resource
from secure_weread_session import SessionStore
from secure_txt_zero_time import TxtZeroTimeStore
from verify_txt_full_summary import Probe as FullProbe,resolve
from txt_full_summary import prepare,payload,digest,receipt_summary
from verify_position_roundtrip import validate_payload,acknowledged
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE
from web_reader_config import URL as CONFIG,token
from shelf_flag_change_contract import state_hash


def baseline_digest(point):
    return digest({key:value for key,value in point.items() if key!='updated_at'})


class Probe(FullProbe):
    def guard(self,stage,url,body):
        if stage=='write_enter':raise ValueError('txt_zero/no_enter')
        if stage=='web_config' and self.authenticated and url==CONFIG and body is None:return
        return super().guard(stage,url,body)
    def send(self,stage,body,claim):
        if stage!='write_same' or self.posts!=0 or self.pending:raise ValueError('txt_zero/consumed')
        validate_payload(self.wire,stage,body)
        if body.get('rt')!=0:raise ValueError('txt_zero/time')
        claim();self.posts=1;self.pending=(stage,digest(body))
        try:return self.request(stage,BASE+'/web/book/read',body)
        finally:self.pending=None


def run(web,session,saved,intent,report,apply=False):
    if not web.find_sample(limit=16):raise ValueError('txt_zero/no_sample')
    plan=web.inspect_plan();current_token=token(web.request('web_config',CONFIG))
    plan['context']['token']=current_token;web.wire=prepare(plan)
    shelf_hash=state_hash(web.request('shelf',BASE+'/web/shelf/sync'))
    web.verify_account();save_refreshed_web_session(session,saved,web);saved=session.load();grant=digest(saved)
    static=dict(point=web.wire['baseline'],ps=web.wire['context']['psvts'],pc=web.wire['pclts'],token=current_token)
    bound=dict(protocol=intent.protocol,owner_sha256=digest(saved['vid']),grant_sha256=grant,
        source_sha256=hashlib.sha256(web.sample['plain'].encode()).hexdigest(),baseline_sha256=baseline_digest(web.wire['baseline']),
        shelf_sha256=shelf_hash,request_sha256=digest(static))
    report.update(result='TXT_ZERO_TIME_PLAN_VERIFIED',current_config_token_read=True,summary_scalars=len(web.wire['baseline']['summary']),
        planned_posts=1,planned_read_seconds=0,enter_posts=0)
    web.exact(web.wire['baseline'],shelf_hash)
    if not apply:return
    receipt=intent.reserve(bound)
    try:
        web.exact(web.wire['baseline'],shelf_hash);body=payload(web.wire,'write_same')
        def claim():
            nonlocal receipt
            if digest(session.load())!=grant:raise ValueError('txt_zero/grant_changed')
            receipt=intent.advance(receipt,'prepared','same_pending')
        try:ack=web.send('write_same',body,claim)
        except Exception:
            if web.posts:
                try:web.exact(web.wire['baseline'],shelf_hash);report['original_readback']=True
                except Exception:report['original_readback']=False
            raise
        report['receipt']=receipt_summary(ack);web.exact(web.wire['baseline'],shelf_hash);report['original_readback']=True
        if not acknowledged(ack):raise ValueError('txt_zero/ack')
        report['acknowledged']=True;intent.advance(receipt,'same_pending','retired')
        report.update(result='TXT_FULL_SUMMARY_ZERO_TIME_SAME_POINT_VERIFIED',original_point_summary_and_visible_shelf_unchanged=True)
    except Exception:
        state,_r=intent.read()
        if state['phase']=='prepared':intent.advance(receipt,'prepared','aborted')
        raise


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    mode=parser.add_mutually_exclusive_group();mode.add_argument('--apply',action='store_true');mode.add_argument('--resolve',action='store_true');args=parser.parse_args(argv)
    if (args.apply or args.resolve) and not args.saved_session:parser.error('saved session required')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,authentication_posts=0,enter_posts=0,
        private_data_on_regular_disk=False,production_upload_enabled=False)
    web=saved=session=intent=None
    try:
        if args.saved_session:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0))
            from verify_native_thought_trial import other_pending
            if other_pending(exclude_txt_zero_time=args.resolve):raise ValueError('txt_zero/other_pending')
            intent=TxtZeroTimeStore()
            if args.apply and intent.read()[0] is not None:raise ValueError('txt_zero/consumed')
            session=SessionStore();saved=session.load()
            if saved.get('web',{}).get('renewal_pending'):raise ValueError('txt_zero/renewal_pending')
            web=Probe();web.vid=saved['vid']
            for k,v in saved['cookies'].items():web.set_cookie(k,v)
            web.verify_account()
            if args.resolve:resolve(web,intent,report,baseline_fingerprint=baseline_digest)
            else:run(web,session,saved,intent,report,args.apply)
    except Exception:report['result']='UNVERIFIED'
    finally:
        if web:
            report['account_data_posts']=web.posts
            if web.authenticated:
                try:web.verify_account();save_refreshed_web_session(session,session.load(),web)
                except Exception:report['result']='UNVERIFIED'
            report['stages']=[{k:row[k] for k in ('stage','status','api_code') if k in row} for row in web.report['stages']]
            web.sample=None;web.close()
        if intent:
            try:state,_r=intent.read();report['intent_phase']=state['phase'] if state else 'absent'
            except Exception:report['intent_phase']='unverified'
        if saved:saved.clear()
    print(json.dumps(report,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
