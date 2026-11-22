#!/usr/bin/env python3
"""Prepare or execute one guarded real ordinary reconnect experiment.

Default and --saved-session remain read-only. --prepare reserves one private
scope without sending; --apply consumes it without retry. Reader/source/cookies
stay in memory or tmpfs. Ambiguous outcomes remain pending.
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
from shelf_flag_change_contract import state_hash
from readtime_upload_model import integer
from secure_native_session import NativeSessionStore
from secure_ordinary_reconnect_trial import PROTOCOL, validate_plan
from secure_ordinary_reconnect_trial import OrdinaryReconnectStore,OrdinaryReconnectRetryStore
from secure_weread_session import COOKIE_NAMES, SessionStore
from txt_full_summary import digest
from verify_cb_fixture_reconnect_trial import run_ui, source_summary
from verify_cb_txt_manual_fixture_ui_trial import manual_command
from verify_eink_login import BASE as NATIVE
from verify_native_txt_position import Native
from verify_ordinary_reconnect_preview import RestorablePreflight, build_payload
from verify_position_roundtrip import same_position
from verify_reader_context import project as reader_context
from verify_reader_progress import find_node, project
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE as WEB


class Reads(Native):
    max_reads=128


def shelf_difference_paths(first,second):
    """Summarize changed field names without exposing book or account data."""
    known={'books','bookInfo','bookId','archive','synckey','syncKey','lectureSynckey','serverTime','updateTime','readUpdateTime',
           'version','data','items','total','removed','updated','created','timestamp','currentTime','list',
           'readingTime','recordReadingTime','ttsTime','bookIds','albumIds','archiveId'}
    paths=set();visited=0
    def walk(a,b,path,depth):
        nonlocal visited
        visited+=1
        if visited>100000 or len(paths)>=32:return
        if type(a) is not type(b) or depth>=6:
            if a!=b:paths.add(path or '/')
        elif isinstance(a,dict):
            for key in a.keys()|b.keys():
                name=key if isinstance(key,str) and key in known else '*'
                child=path+'/'+name
                if key not in a or key not in b:paths.add(child)
                else:walk(a[key],b[key],child,depth+1)
        elif isinstance(a,list):
            if len(a)!=len(b):paths.add(path+'/length')
            for left,right in zip(a,b):walk(left,right,path+'/*',depth+1)
        elif a!=b:paths.add(path or '/')
    walk(first,second,'',0)
    return sorted(paths)[:32]


def stable_shelf(value):
    """Preserve all shelf fields except the observed time-varying cursor."""
    if not isinstance(value,dict):raise ValueError('ordinary_rpc/shelf')
    result=deepcopy(value)
    if 'lectureSynckey' in result:
        if not integer(result['lectureSynckey'],0,2**53-1):raise ValueError('ordinary_rpc/shelf')
        del result['lectureSynckey']
    return result


def same_shelf(first,second):
    if not isinstance(first,dict) or not isinstance(second,dict):return False
    if ('lectureSynckey' in first)!=('lectureSynckey' in second):return False
    if 'lectureSynckey' in first and (not integer(first['lectureSynckey'],0,2**53-1)
            or not integer(second['lectureSynckey'],0,2**53-1) or second['lectureSynckey']<first['lectureSynckey']):return False
    return stable_shelf(first)==stable_shelf(second)


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
    mode=p.add_mutually_exclusive_group();mode.add_argument('--prepare',action='store_true');mode.add_argument('--apply',action='store_true')
    p.add_argument('--retry',action='store_true',help='use the distinct follow-up trial scope')
    p.add_argument('--width',type=int,default=1264);p.add_argument('--height',type=int,default=1680);p.add_argument('--dpi',type=int,default=300);a=p.parse_args(argv)
    if not all(1<=v<=4096 for v in (a.width,a.height,a.dpi)):p.error('bounded display required')
    if (a.prepare or a.apply) and not a.saved_session:p.error('prepared trial requires saved session')
    if a.retry and not (a.prepare or a.apply):p.error('retry scope requires a trial mode')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,
                authentication_posts=0,private_data_on_regular_disk=False,guarded_write_mode=False)
    web=native=saved=grant=payload=restore_web=journal=None;private=set();live_report={}
    try:
        if a.saved_session:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0));report['phase']='environment'
            if a.prepare or a.apply:report['retry_scope']=a.retry
            if a.prepare or a.apply:
                from verify_native_thought_trial import other_pending
                journal=(OrdinaryReconnectRetryStore if a.retry else OrdinaryReconnectStore)();state,_receipt=journal.read()
                if (a.prepare and state is not None or a.apply and (not state or state['phase']!='prepared')
                        or other_pending(exclude_ordinary_reconnect_trial=a.apply and not a.retry,
                                         exclude_ordinary_reconnect_retry=a.apply and a.retry)):
                    raise ValueError('ordinary_rpc/intent')
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
            scope={};bound={}
            def check_context(html):
                context=reader_context(dict(book_id=web.book_id),html)
                embedded=project(dict(book=context['progress']),web.book_id)
                if (not same_position(embedded,baseline) or 'summary' in context['progress']
                        and context['progress']['summary']!=baseline['summary']):raise ValueError('ordinary_rpc/context')
                fixed=context.get('pclts')
                if fixed is None or type(fixed) is str and fixed in ('','0') or type(fixed) is int and fixed==0:fixed=None
                scope.update(context=context,pclts=fixed)
                return True
            def check_body(value):
                if not isinstance(value,dict) or type(value.get('pr')) is not int:return False
                context,fixed=scope['context'],scope['pclts']
                selected=dict(protocol=PROTOCOL,owner_sha256=digest(web.vid),grant_sha256=digest(grant),
                    web_session_sha256=digest(saved),source_sha256=source_sha,catalog_sha256=digest(catalog),
                    web_shelf_sha256=digest(stable_shelf(web_shelf)),native_shelf_sha256=digest(stable_shelf(native_shelf)),baseline=point,
                    target=dict(point,chapter_offset=offset,raw_percent=value['pr'],summary=target_summary),
                    counts=initial['counts'],version=versions[0])
                if a.retry:selected.update(web_shelf_core_sha256=state_hash(web_shelf),native_shelf_core_sha256=state_hash(native_shelf))
                validate_plan(selected)
                target_point=selected['target'];fields={'appId','b','c','ci','co','sm','pr','ct','ps','pc','s'}
                report['body_checks']=dict(fields=set(value)==fields,app=value.get('appId')==web_app_id(),
                    book=value.get('b')==weread_e(target_point['book_id']),chapter=value.get('c')==weread_e(target_point['chapter_uid']),
                    index=value.get('ci')==target_point['chapter_idx'],offset=value.get('co')==target_point['chapter_offset'],
                    summary=value.get('sm')==target_point['summary'],percent=value.get('pr')==target_point['raw_percent'],
                    reader_session=value.get('ps')==context.get('psvts'),counter=value.get('pc')==(fixed if fixed is not None else value.get('pc')),
                    fresh=type(value.get('ct')) is int and 0<=int(time.time())-value['ct']<=30,
                    signature=value.get('s')==weread_sign(sorted_query({k:v for k,v in value.items() if k!='s'})))
                validate_body(selected,context,fixed,'enter',value);bound.update(valid=True,plan=selected)
                return True
            report['phase']='native';dry={};preview(rpc_command,payload,check_body,dry,check_context=check_context)
            if dry.get('result')!='READER_POSITION_DRY_VERIFIED' or not bound.get('valid'):raise ValueError('ordinary_rpc/dry')
            report['phase']='readback';web.verify_account();web.inspect(web.book_id)
            report['readback_checks']=dict(web_position=project(web.raw_progress,web.book_id)==before,web_catalog=web.catalog==catalog,
                web_source=hashlib.sha256(decode_content_shards(*(web.shards[k] for k in ('e_0','e_1','e_3'))).encode()).hexdigest()==source_sha,
                web_snapshot=bool(web.report.get('read_snapshot_consistent')))
            if not all(report['readback_checks'].values()):raise ValueError('ordinary_rpc/changed')
            after=native_snapshot(native,grant,web.book_id,baseline)
            report['readback_checks']['native_position_and_counts']=after==initial
            web_shelf_after=web.request('shelf',WEB+'/web/shelf/sync')
            native_shelf_after=native.request('ordinary_rpc_shelf',NATIVE+'/shelf/sync',credentials=grant)
            report['readback_checks']['web_shelf']=digest(web_shelf_after)==digest(web_shelf)
            report['readback_checks']['native_shelf']=digest(native_shelf_after)==digest(native_shelf)
            report['shelf_core_checks']=dict(web=state_hash(web_shelf_after)==state_hash(web_shelf),
                                             native=state_hash(native_shelf_after)==state_hash(native_shelf))
            report['shelf_stable_fields']=dict(web=same_shelf(web_shelf,web_shelf_after),native=same_shelf(native_shelf,native_shelf_after))
            if not report['readback_checks']['web_shelf']:
                report['web_shelf_changed_fields']=shelf_difference_paths(web_shelf,web_shelf_after)
            if not report['readback_checks']['native_shelf']:
                report['native_shelf_changed_fields']=shelf_difference_paths(native_shelf,native_shelf_after)
            if (not all(value for key,value in report['readback_checks'].items() if key not in ('web_shelf','native_shelf'))
                    or not all(report['shelf_core_checks'].values()) or not all(report['shelf_stable_fields'].values())):
                raise ValueError('ordinary_rpc/changed')
            if NativeSessionStore().load(saved['vid'])!=grant:raise ValueError('ordinary_rpc/session')
            report['phase']='independent_host_check'
            from ordinary_reconnect_observe import check as independent_check
            def current():
                cookies={cookie.name:cookie.value for cookie in web.cookies
                         if cookie.name in COOKIE_NAMES and cookie.domain in ('.weread.qq.com','weread.qq.com') and cookie.path=='/'}
                return (store.load()==saved and NativeSessionStore().load(saved['vid'])==grant and cookies==saved['cookies']
                        and not ((a.prepare or a.apply) and other_pending(exclude_ordinary_reconnect_trial=a.apply and not a.retry,
                                                                          exclude_ordinary_reconnect_retry=a.apply and a.retry)))
            independent_check(web,native,grant,bound['plan'],bound['plan']['baseline'],current)
            if a.prepare:
                if journal.read()[0] is not None or not current():raise ValueError('ordinary_rpc/intent')
                journal.reserve(bound['plan'])
                state,_=journal.read()
                if not state or state['phase']!='prepared' or state['plan']!=bound['plan']:raise ValueError('ordinary_rpc/intent')
                report['trial_intent_prepared']=True
            elif a.apply:
                from ordinary_reconnect_live import execute as execute_trial
                from ordinary_reconnect_restore import RestoreProbe
                state,_=journal.read()
                if not state or state['phase']!='prepared' or state['plan']!=bound['plan'] or not current():
                    raise ValueError('ordinary_rpc/intent')
                if manual_command()!=command:raise ValueError('ordinary_rpc/command')
                restore_web=RestoreProbe();restore_web.vid=web.vid;restore_web.book_id=web.book_id
                for key,value in saved['cookies'].items():restore_web.set_cookie(key,value)
                restore_web.verify_account()
                if not current():raise ValueError('ordinary_rpc/session')
                live_command=rpc_command[:-1]
                if rpc_command[-1]!='--dry':raise ValueError('ordinary_rpc/command')
                report['phase']='live';report['account_data_posts']=None
                execute_trial(journal,bound['plan'],payload,live_command,web,native,grant,restore_web,current,live_report)
                if live_report.get('result')!='ORDINARY_RECONNECT_TRIAL_VERIFIED':raise ValueError('ordinary_rpc/live')
                report['account_data_posts']=3;report['real_reader_roundtrip_verified']=True
            web.verify_account();save_refreshed_web_session(store,saved,web)
            report.update(result='ORDINARY_RECONNECT_TRIAL_VERIFIED' if a.apply else 'ORDINARY_RECONNECT_TRIAL_PREPARED' if a.prepare else 'ORDINARY_RPC_REAL_SOURCE_DRY_VERIFIED',phase='complete',screen_selection=web.report['selection_screen'],
                          signed_body_bound=True,dynamic_counter_checked=scope['pclts'] is None,independent_dual_readback=True,independent_host_check=True,
                          original_summary_preserved=True,source_catalog_and_stable_shelf_fields_unchanged=True,profile_removed=True)
    except Exception as error:
        report['result']='UNVERIFIED'
        if isinstance(error,ValueError) and re.fullmatch('ordinary_rpc/[a-z_]+',str(error)):report['reason']=str(error)
        else:
            frames=traceback.extract_tb(error.__traceback__)
            report['diagnostic']={'type':type(error).__name__,
                                  'frames':[{'function':item.name,'line':item.lineno} for item in frames[-3:]]}
    finally:
        if live_report:
            report['live']={key:live_report[key] for key in ('result','dry_verified','claimed_posts','acknowledged_posts','independently_verified',
                'claim_interrupted','restore_claimed','restore_claim_interrupted','restore_acknowledged','restoration_verified') if key in live_report}
            if a.apply and report['result']!='ORDINARY_RECONNECT_TRIAL_VERIFIED' and not (live_report.get('claimed_posts')
                    or live_report.get('claim_interrupted') or live_report.get('restore_claimed') or live_report.get('restore_claim_interrupted')):
                report['account_data_posts']=0
        if restore_web:
            report['restore_web_stages']=[{k:row[k] for k in ('stage','status','api_code') if k in row} for row in restore_web.report['stages']]
            restore_web.close()
        if web:
            if web.authenticated:
                try:web.verify_account();save_refreshed_web_session(store,store.load(),web)
                except Exception:report['result']='UNVERIFIED';report['reason']='ordinary_rpc/session'
            report['web_stages']=[{k:row[k] for k in ('stage','status','api_code') if k in row} for row in web.report['stages']]
            web.shards.clear();web.close()
        if native:
            report['native_stages']=[{k:row[k] for k in ('stage','status','error_code') if k in row} for row in native.report['stages']]
        for value in (saved,grant,payload):
            if isinstance(value,dict):value.clear()
    encoded=json.dumps(report,ensure_ascii=True)
    if any(len(v)>=8 and (v in encoded or json.dumps(v,ensure_ascii=True)[1:-1] in encoded) for v in private):
        report=dict(result='UNVERIFIED',reason='ordinary_rpc/privacy',account_data_posts=0,authentication_posts=0)
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')

if __name__=='__main__':raise SystemExit(main())
