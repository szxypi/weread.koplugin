#!/usr/bin/env python3
"""Read-only real-source rehearsal of the private ordinary reconnect bridge.

No write-capable option exists. Reader/source/cookies stay in memory or tmpfs.
The proposed body is checked and the child is required to deny HTTP dispatch.
"""
import argparse
from copy import deepcopy
from datetime import datetime, timezone
import hashlib
import json
import re
import resource
import secrets
import traceback
import time

from fetch_weread_epub import decode_content_shards, weread_e, web_app_id, weread_sign, sorted_query
from ordinary_reconnect_body_guard import validate_body
from ordinary_reconnect_broker import preview
from readtime_upload_model import integer
from secure_native_session import NativeSessionStore
from secure_ordinary_reconnect_trial import PROTOCOL, validate_plan
from secure_weread_session import SessionStore
from txt_full_summary import digest
from verify_cb_fixture_reconnect_trial import run_ui, source_summary
from verify_cb_txt_manual_fixture_ui_trial import manual_command
from verify_eink_login import BASE as NATIVE
from verify_native_txt_position import Native
from verify_ordinary_reconnect_preview import RestorablePreflight, build_payload
from verify_position_roundtrip import same_position
from verify_reader_progress import find_node, project
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE as WEB


class Reads(Native):
    max_reads=24


def native_snapshot(native, grant, book, baseline):
    raw=native.request('ordinary_rpc_progress',NATIVE+'/book/getProgress?bookId='+book,credentials=grant)
    node=find_node(raw,book);point=project(raw,book,'native')
    if not same_position(point,baseline) or node.get('summary')!=baseline['summary']:
        raise ValueError('ordinary_rpc/native_position')
    counts={key:node.get(key) for key in ('readingTime','recordReadingTime','ttsTime')}
    if any(not integer(value,0,2**53-1) for value in counts.values()):raise ValueError('ordinary_rpc/counts')
    return dict(point=point,counts=counts)


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--saved-session',action='store_true')
    p.add_argument('--width',type=int,default=1264);p.add_argument('--height',type=int,default=1680);p.add_argument('--dpi',type=int,default=300);a=p.parse_args(argv)
    if not all(1<=v<=4096 for v in (a.width,a.height,a.dpi)):p.error('bounded display required')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,
                authentication_posts=0,private_data_on_regular_disk=False,guarded_write_mode=False)
    web=saved=grant=payload=None;private=set()
    try:
        if a.saved_session:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0));report['phase']='environment'
            command=manual_command();rpc_command=list(command)
            target='/source/scripts/run_cb_fixture_manual_ui.py'
            if rpc_command.count(target)!=1:raise ValueError('ordinary_rpc/command')
            rpc_command[rpc_command.index(target)]='/source/scripts/run_ordinary_reconnect_trial.py'
            rpc_command.extend(['--width',str(a.width),'--height',str(a.height),'--dpi',str(a.dpi),'--dry'])
            store=SessionStore();saved=store.load();grant=NativeSessionStore().load(saved['vid']);web=RestorablePreflight();web.vid=saved['vid']
            private.update(str(v) for v in saved['cookies'].values());private.update(str(v) for v in grant.values() if isinstance(v,str))
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            report['phase']='source';web.verify_account();web.prepare()
            if not web.plan['same_position_summary_preserved'] or not web.report.get('read_snapshot_consistent'):
                raise ValueError('ordinary_rpc/source')
            baseline=deepcopy(web.plan['baseline']);before=project(web.raw_progress,web.book_id)
            source=decode_content_shards(*(web.shards[k] for k in ('e_0','e_1','e_3')))
            source_sha=hashlib.sha256(source.encode()).hexdigest();catalog=deepcopy(web.catalog);web_shelf=deepcopy(web.shelf)
            private.add(web.book_id);private.add(baseline['summary'])
            native=Reads(grant,web.book_id);initial=native_snapshot(native,grant,web.book_id,baseline)
            info=native.request('ordinary_rpc_info',NATIVE+'/book/info?bookId='+web.book_id,credentials=grant)
            versions=[info[k] for k in ('bookVersion','version') if k in info]
            if (str(info.get('bookId'))!=web.book_id or not versions
                    or any(not integer(v,0,2147483647) or v!=versions[0] for v in versions)):
                raise ValueError('ordinary_rpc/version')
            native_shelf=native.request('ordinary_rpc_shelf',NATIVE+'/shelf/sync',credentials=grant)
            web.verify_account();save_refreshed_web_session(store,saved,web);saved=store.load()
            payload,model=build_payload(web,saved);payload['book_version']=versions[0]
            report['phase']='discovery';discovered=run_ui(command,payload,a.width,a.height,a.dpi);offset=discovered['offset']
            if offset==payload['first_offset']:raise ValueError('ordinary_rpc/movement')
            target_summary=source_summary(model,offset);private.add(target_summary)
            payload.pop('reconnect_discover');payload.update(next_offset=offset,expected_summary=target_summary,
                                                             ordinary_trial=dict(rpc_token=secrets.token_hex(16)))
            point={key:baseline[key] for key in ('book_id','chapter_uid','chapter_idx','chapter_offset','raw_percent','summary')}
            point['book_id'],point['chapter_uid']=str(point['book_id']),str(point['chapter_uid'])
            context=deepcopy(web.plan['context']);fixed=context.get('pclts')
            if fixed is None or type(fixed) is str and fixed in ('','0') or type(fixed) is int and fixed==0:fixed=None
            bound={}
            def check_body(value):
                if not isinstance(value,dict) or type(value.get('pr')) is not int:return False
                selected=dict(protocol=PROTOCOL,owner_sha256=digest(web.vid),grant_sha256=digest(grant),
                    web_session_sha256=digest(saved),source_sha256=source_sha,catalog_sha256=digest(catalog),
                    web_shelf_sha256=digest(web_shelf),native_shelf_sha256=digest(native_shelf),baseline=point,
                    target=dict(point,chapter_offset=offset,raw_percent=value['pr'],summary=target_summary),
                    counts=initial['counts'],version=versions[0])
                validate_plan(selected)
                target_point=selected['target'];fields={'appId','b','c','ci','co','sm','pr','ct','ps','pc','s'}
                report['body_checks']=dict(fields=set(value)==fields,app=value.get('appId')==web_app_id(),
                    book=value.get('b')==weread_e(target_point['book_id']),chapter=value.get('c')==weread_e(target_point['chapter_uid']),
                    index=value.get('ci')==target_point['chapter_idx'],offset=value.get('co')==target_point['chapter_offset'],
                    summary=value.get('sm')==target_point['summary'],percent=value.get('pr')==target_point['raw_percent'],
                    reader_session=value.get('ps')==context.get('psvts'),counter=value.get('pc')==(fixed if fixed is not None else value.get('pc')),
                    fresh=type(value.get('ct')) is int and 0<=int(time.time())-value['ct']<=30,
                    signature=value.get('s')==weread_sign(sorted_query({k:v for k,v in value.items() if k!='s'})))
                validate_body(selected,context,fixed,'enter',value);bound['valid']=True
                return True
            report['phase']='native';dry={};preview(rpc_command,payload,check_body,dry)
            if dry.get('result')!='READER_POSITION_DRY_VERIFIED' or not bound.get('valid'):raise ValueError('ordinary_rpc/dry')
            report['phase']='readback';web.verify_account();web.inspect(web.book_id)
            if (project(web.raw_progress,web.book_id)!=before or web.catalog!=catalog
                    or hashlib.sha256(decode_content_shards(*(web.shards[k] for k in ('e_0','e_1','e_3'))).encode()).hexdigest()!=source_sha
                    or not web.report.get('read_snapshot_consistent')):raise ValueError('ordinary_rpc/changed')
            after=native_snapshot(native,grant,web.book_id,baseline)
            if after!=initial or digest(web.request('shelf',WEB+'/web/shelf/sync'))!=digest(web_shelf):raise ValueError('ordinary_rpc/changed')
            if digest(native.request('ordinary_rpc_shelf',NATIVE+'/shelf/sync',credentials=grant))!=digest(native_shelf):raise ValueError('ordinary_rpc/changed')
            if NativeSessionStore().load(saved['vid'])!=grant:raise ValueError('ordinary_rpc/session')
            web.verify_account();save_refreshed_web_session(store,saved,web)
            report.update(result='ORDINARY_RPC_REAL_SOURCE_DRY_VERIFIED',phase='complete',screen_selection=web.report['selection_screen'],
                          signed_body_bound=True,dynamic_counter_checked=fixed is None,independent_dual_readback=True,
                          original_summary_preserved=True,source_catalog_shelves_unchanged=True,profile_removed=True)
    except Exception as error:
        report['result']='UNVERIFIED'
        if isinstance(error,ValueError) and re.fullmatch('ordinary_rpc/[a-z_]+',str(error)):report['reason']=str(error)
        else:
            frames=traceback.extract_tb(error.__traceback__)
            report['diagnostic']={'type':type(error).__name__,
                                  'frames':[{'function':item.name,'line':item.lineno} for item in frames[-3:]]}
    finally:
        if web:
            if web.authenticated:
                try:web.verify_account();save_refreshed_web_session(store,store.load(),web)
                except Exception:report['result']='UNVERIFIED';report['reason']='ordinary_rpc/session'
            web.shards.clear();web.close()
        for value in (saved,grant,payload):
            if isinstance(value,dict):value.clear()
    encoded=json.dumps(report,ensure_ascii=True)
    if any(len(v)>=8 and (v in encoded or json.dumps(v,ensure_ascii=True)[1:-1] in encoded) for v in private):
        report=dict(result='UNVERIFIED',reason='ordinary_rpc/privacy',account_data_posts=0,authentication_posts=0)
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')

if __name__=='__main__':raise SystemExit(main())
