#!/usr/bin/env python3
"""Distinct scoped native worker trial; default offline, no POST replay."""
import argparse
from copy import deepcopy
from datetime import datetime,timezone
import json
import math
import resource
import secrets
import subprocess
import time
from secure_weread_session import SessionStore
from secure_native_session import NativeSessionStore
from secure_native_txt_roundtrip import NativeTxtRoundtripStore,NATIVE_PROTOCOL
from native_position_flow_contract import validate_payload,validate_stage
from native_trial_pipe import Frames,write_initial,reply,stop
from verify_native_txt_position import Native,Source
from verify_native_txt_roundtrip import make_plan,check,run as recover
from verify_translation_preflight import save_refreshed_web_session
from verify_eink_login import BASE
from native_txt_read_model import body
from readtime_upload_model import local_zone
from shelf_flag_change_contract import state_hash
from txt_full_summary import digest
from verify_native_position_lua import equivalent


class Reads(Native):max_reads=48


def wire_integer(value,low,high):
    if type(value) not in (int,float) or not math.isfinite(value) or value%1 or not low<=value<=high:raise ValueError('native_position_flow/clock')
    return int(value)


def mock_payload(armed):
    credentials=dict(vid='900000',accessToken='synthetic-native-access',refreshToken='synthetic-native-refresh',deviceId='eink334691225'+'1'*19)
    before=dict(book_id='41',chapter_uid='2',chapter_idx=3,chapter_offset=12,raw_percent=17,summary='synthetic original full summary')
    target=dict(before,chapter_offset=13,summary=before['summary'][1:]+'x')
    shelf=state_hash(dict(books=[dict(bookId='41',secret=0,finishReading=0)],archive=[]))
    plan=dict(protocol=NATIVE_PROTOCOL,owner_sha256=digest(credentials['vid']),grant_sha256=digest(credentials),source_sha256='a'*64,catalog_sha256='b'*64,
        shelf_sha256=shelf,baseline=before,target=target,counts=dict(readingTime=10,recordReadingTime=20,ttsTime=0),version=0,chapter_progress=None)
    return dict(credentials=credentials,plan=plan,native_shelf_sha256=shelf,shelf_books=1,guest='5ecdcfd7f',time_zone='+08:00',permit_writes=armed,rpc_token=secrets.token_hex(16),mock=True)


def validate_result(value,armed,mocked):
    if not isinstance(value,dict) or set(value)!={'result','profile_removed','installed','stage'} or value['result'] not in ('PASS','UNVERIFIED') or type(value['profile_removed']) is not bool:raise ValueError('native_position_flow/result')
    if value['stage'] is not None:
        validate_stage(value['stage'],armed)
        if value['stage']['mock'] is not mocked:raise ValueError('native_position_flow/mock')
    if value['result']=='PASS':
        if (not value['profile_removed'] or value['stage'] is None or value['stage']['result']!='PASS'
                or not isinstance(value['installed'],dict) or set(value['installed'])!={'files','bytes_match'} or value['installed']['bytes_match'] is not True
                or type(value['installed']['files']) is not int or not 1<=value['installed']['files']<=1000):raise ValueError('native_position_flow/incomplete')
    return value


def execute(payload,command,intent,report,*,before=None,after=None,current=None):
    armed=payload['permit_writes'];validate_payload(payload,armed)
    receipt=None;child=None;awaiting=None;body_steps=ack_steps=verified_steps=0
    if intent.read()[0] is not None:raise ValueError('native_position_flow/consumed')
    try:
        child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
        write_initial(child.stdin,payload);frames=Frames(child.stdout,payload['rpc_token'],timeout=300)
        while True:
            kind,value=frames.next()
            if kind=='RESULT':
                runner=validate_result(value,armed,payload['mock']);report['native_ui']=runner;break
            awaiting=value
            event=value.get('kind');seq=value.get('seq')
            if type(seq) is not int or not 1<=seq<=2:raise ValueError('native_position_flow/sequence')
            if event in ('claim','dry_body'):
                if set(value)!={'kind','seq','body'} or seq!=verified_steps+1 or body_steps!=verified_steps or event!=('claim' if armed else 'dry_body'):raise ValueError('native_position_flow/body_sequence')
                candidate=value['body'];stamp=wire_integer(candidate.get('timestamp'),1,4102444800);random=wire_integer(candidate.get('random'),0,999)
                if not 0<=time.time()-stamp<=30:raise ValueError('native_position_flow/clock')
                expected=body(payload['credentials'],payload['plan']['target' if seq==1 else 'baseline'],payload['plan']['version'],payload['guest'],stamp,random,payload['time_zone'])
                if not equivalent(expected,candidate):raise ValueError('native_position_flow/body')
                if current:current()
                if before:before(seq)
                if armed:
                    if receipt is None:receipt=intent.reserve(payload['plan'])
                    receipt=intent.advance(receipt,'prepared' if seq==1 else 'advance_verified','advance_pending' if seq==1 else 'restore_pending')
                body_steps=seq
            elif event=='ack':
                if not armed or set(value)!={'kind','seq'} or seq!=body_steps or seq!=ack_steps+1:raise ValueError('native_position_flow/ack_sequence')
                receipt=intent.advance(receipt,'advance_pending' if seq==1 else 'restore_pending','advance_acknowledged' if seq==1 else 'restore_acknowledged');ack_steps=seq
            elif event=='verified':
                if not armed or set(value)!={'kind','seq'} or seq!=ack_steps or seq!=verified_steps+1:raise ValueError('native_position_flow/verified_sequence')
                if current:current()
                if after:after(seq)
                receipt=intent.advance(receipt,'advance_acknowledged' if seq==1 else 'restore_acknowledged','advance_verified' if seq==1 else 'retired');verified_steps=seq
            else:raise ValueError('native_position_flow/event')
            reply(child.stdin,dict(kind=event,seq=seq,ok=True));awaiting=None
        if child.wait(timeout=15) or runner['result']!='PASS' or verified_steps!=(2 if armed else 0) or body_steps!=(2 if armed else 1):raise ValueError('native_position_flow/native_failed')
        report.update(result='MOCK_NATIVE_POSITION_FLOW_VERIFIED' if payload['mock'] else 'NATIVE_POSITION_FLOW_VERIFIED' if armed else 'NATIVE_POSITION_FLOW_DISARMED_VERIFIED',
            account_data_posts=0 if payload['mock'] or not armed else 2,synthetic_posts=2 if payload['mock'] and armed else 0,
            original_restoration_verified=armed,independent_steps=verified_steps,body_guards_verified=body_steps,explicit_success_receipts=ack_steps,
            actual_native_write_flow_verified=armed and not payload['mock'],no_automatic_replay=True)
    except (Exception,KeyboardInterrupt) as error:
        report.update(result='UNVERIFIED',body_guards_verified=body_steps,explicit_success_receipts=ack_steps,independent_steps=verified_steps,
            account_data_posts=0 if payload['mock'] or not armed else body_steps,no_automatic_replay=True)
        if isinstance(error,ValueError) and str(error) in {'native_position_flow/sequence','native_position_flow/body_sequence','native_position_flow/clock',
                'native_position_flow/body','native_position_flow/ack_sequence','native_position_flow/verified_sequence','native_position_flow/event','native_position_flow/native_failed','native_position_flow/grant',
                'native_txt/position','native_txt/time_changed','native_txt/web_changed','native_txt/shelf_changed','txt_roundtrip/source','txt_roundtrip/position','txt_roundtrip/version'}:report['reason']=str(error)
        if child is not None and child.poll() is None and awaiting is not None:
            try:reply(child.stdin,dict(kind=awaiting.get('kind'),seq=awaiting.get('seq'),ok=False))
            except Exception:pass
        raise
    finally:
        if child is not None:stop(child)


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--saved-session',action='store_true');p.add_argument('--mock',action='store_true')
    modes=p.add_mutually_exclusive_group();modes.add_argument('--apply',action='store_true');modes.add_argument('--dry-run',action='store_true');modes.add_argument('--resolve',action='store_true');modes.add_argument('--restore-only',action='store_true')
    p.add_argument('--native-ui-command',nargs=argparse.REMAINDER);a=p.parse_args(argv)
    if a.mock and a.saved_session or (a.apply or a.dry_run) and (not (a.mock or a.saved_session) or not a.native_ui_command) or (a.resolve or a.restore_only) and (not a.saved_session or a.native_ui_command):p.error('invalid saved/native flow mode')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,authentication_posts=0,private_data_on_regular_disk=False,production_upload_enabled=False)
    web=native=saved=credentials=intent=payload=None
    try:
        resource.setrlimit(resource.RLIMIT_CORE,(0,0))
        if a.mock:
            from test_secure_native_session import Backend
            payload=mock_payload(a.apply);intent=NativeTxtRoundtripStore(Backend(),native=True)
        elif a.saved_session:
            from verify_native_thought_trial import other_pending
            if other_pending(exclude_native_txt_flow=a.resolve or a.restore_only):raise ValueError('native_position_flow/pending')
            intent=NativeTxtRoundtripStore(native=True);state,_r=intent.read()
            if a.apply and state is not None:raise ValueError('native_position_flow/consumed')
            session=SessionStore();saved=session.load();credentials=NativeSessionStore().load(saved['vid']);web=Source();web.vid=saved['vid']
            if state and (a.resolve or a.restore_only) and digest(web.vid)!=state['plan']['owner_sha256']:raise ValueError('native_position_flow/owner')
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account();identity=state['plan']['baseline']['book_id'] if state and (a.resolve or a.restore_only) else None
            if not web.find_sample(book_id=identity,limit=16):raise ValueError('native_position_flow/no_sample')
            native=Reads(credentials,web.book_id)
            if a.resolve or a.restore_only:
                if a.restore_only:
                    from verify_native_txt_roundtrip import Probe
                    native=Probe(credentials,web.book_id,restore_only=True)
                recover(web,native,credentials,session,saved,intent,report,restore_only=a.restore_only,resolving=a.resolve)
            else:
                plan,guest=make_plan(web,native,credentials,report);plan['protocol']=NATIVE_PROTOCOL
                if plan['chapter_progress'] is not None:raise ValueError('native_position_flow/chapter_progress')
                shelf=native.request('native_flow_shelf',BASE+'/shelf/sync',credentials=credentials)
                check(web,native,credentials,plan,plan['baseline'],refresh=True)
                payload=dict(credentials=credentials,plan=plan,native_shelf_sha256=state_hash(shelf),shelf_books=len(shelf['books']),guest=guest,time_zone=local_zone(),permit_writes=a.apply,rpc_token=secrets.token_hex(16),mock=False)
                report.update(result='NATIVE_POSITION_FLOW_PLAN_VERIFIED',planned_posts=2,planned_elapsed_seconds=0)
        if payload and (a.apply or a.dry_run):
            def current():
                if not payload['mock'] and (digest(NativeSessionStore().load(web.vid))!=payload['plan']['grant_sha256'] or SessionStore().load()['vid']!=web.vid):raise ValueError('native_position_flow/grant')
            def before(seq):
                if not payload['mock']:check(web,native,credentials,payload['plan'],payload['plan']['baseline' if seq==1 else 'target'],refresh=True)
            def after(seq):
                if not payload['mock']:
                    expected=payload['plan']['target' if seq==1 else 'baseline']
                    check(web,native,credentials,payload['plan'],expected,refresh=True);check(web,native,credentials,payload['plan'],expected)
            execute(payload,a.native_ui_command,intent,report,before=before,after=after,current=current)
            if not payload['mock']:check(web,native,credentials,payload['plan'],payload['plan']['baseline'],refresh=True)
    except (Exception,KeyboardInterrupt):report['result']='UNVERIFIED'
    finally:
        if web:
            if web.authenticated:
                try:web.verify_account();save_refreshed_web_session(session,session.load(),web)
                except Exception:report['result']='UNVERIFIED'
            report['web_stages']=[{k:r[k] for k in ('stage','status','api_code') if k in r} for r in web.report['stages']];web.sample=None;web.close()
        if native:report['native_stages']=[{k:r[k] for k in ('stage','status','error_code') if k in r} for r in native.report['stages']]
        if intent:
            try:state,_r=intent.read();report['intent_phase']=state['phase'] if state else 'absent'
            except Exception:report['intent_phase']='unverified'
        for value in (saved,credentials):
            if value:value.clear()
    print(json.dumps(report,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
