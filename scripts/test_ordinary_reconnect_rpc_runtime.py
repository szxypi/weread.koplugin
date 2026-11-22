#!/usr/bin/env python3
"""Exercise the private RPC bridge against KOReader and a loopback fixture only."""
import argparse
from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import threading
from urllib.parse import quote
from urllib.request import ProxyHandler, Request, build_opener
from unittest.mock import patch

from fetch_weread_epub import weread_e,web_app_id
from mock_weread import BOOK_ID, CHAPTERS, MockServer, chapter_html
from ordinary_reconnect_body_guard import validate_body
from ordinary_reconnect_broker import execute, preview
from ordinary_reconnect_coordinator import Coordinator
from ordinary_reconnect_live import execute as execute_trial
import ordinary_reconnect_observe
import ordinary_reconnect_live
from ordinary_reconnect_restore import RestoreProbe, restore
from ordinary_partial_recovery import RecoveryProbe, binding as recovery_binding, checked_pair, observed_point, restore_once
from secure_ordinary_partial_recovery import PartialRecoveryStore,RetryPartialRecoveryStore,ThirdPartialRecoveryStore
from secure_ordinary_recovery_renewal import RetryRecoveryRenewalStore,ThirdRecoveryRenewalStore
from secure_ordinary_restore_readback import RestoreReadbackStore,ThirdRestoreReadbackStore
from secure_ordinary_reconnect_trial import OrdinaryReconnectStore,OrdinaryReconnectRetryStore,OrdinaryReconnectThirdStore, PROTOCOL, HASHES, entered_point
from test_secure_native_session import Backend
from verify_cb_fixture_reconnect_trial import source_summary
from verify_position_roundtrip import DEFAULT_TOKEN, same_position
from verify_reader_context import project as reader_context
from verify_reader_progress import project as reader_progress
from verify_source_coordinates import FilteredSource
from txt_full_summary import digest
from shelf_flag_change_contract import state_hash
from verify_web_source_progress import BASE as WEB, WebSourceProbe


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--koreader',required=True,type=Path);p.add_argument('--candidate',required=True,type=Path)
    p.add_argument('--width',type=int,default=600);p.add_argument('--height',type=int,default=800);p.add_argument('--dpi',type=int,default=167)
    failure=p.add_mutually_exclusive_group();failure.add_argument('--noack',action='store_true');failure.add_argument('--restore-noack',action='store_true')
    failure.add_argument('--partial-recovery',action='store_true');failure.add_argument('--partial-recovery-noack',action='store_true')
    failure.add_argument('--retry-recovery',action='store_true');failure.add_argument('--retry-recovery-noack',action='store_true')
    failure.add_argument('--retry-restore-noack',action='store_true');failure.add_argument('--retry-success',action='store_true')
    failure.add_argument('--retry-enter-noack',action='store_true')
    failure.add_argument('--retry-enter-read-failure',action='store_true');p.add_argument('--third-scope',action='store_true')
    p.add_argument('--preserve-position-percent',action='store_true');a=p.parse_args()
    retry_recovery_mode=a.retry_recovery or a.retry_recovery_noack or a.retry_enter_noack or a.retry_enter_read_failure
    retry_mode=retry_recovery_mode or a.retry_restore_noack or a.retry_success
    if a.third_scope and not retry_mode:p.error('third scope requires a retry scenario')
    server=MockServer(0);server.content_format='epub';server.dynamic_reader_clock=True;server.enter_preserves_percent=True
    if a.preserve_position_percent:
        if not a.retry_success:p.error('preserved-percent scenario requires success')
        server.position_preserves_percent=True
    if a.retry_enter_noack:server.enter_noack=True
    source=chapter_html(1);model=FilteredSource(source)
    first=model.locate('这是第1章的第16段。我们沿着小路慢慢前行')[0]
    server.progress[BOOK_ID]=dict(chapterUid=1,chapterIdx=1,chapterOffset=first,progress=25,summary='old summary')
    if a.noack or a.retry_recovery or a.retry_recovery_noack:server.control['progress_confirmation']='noack'
    if a.restore_noack or a.retry_restore_noack:
        server.roundtrip_seed=True;server.roundtrip_posts=1;server.control['progress_roundtrip_mode']='restore-noack'
    thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
    try:
        env=dict(os.environ,WEREAD_FIXTURE_SYNTHETIC='1',WEREAD_FIXTURE_MOCK_PORT=str(server.server_port),LD_LIBRARY_PATH=str(a.koreader/'libs'))
        base=[sys.executable,str(Path(__file__).with_name('run_cb_fixture_manual_ui.py')),'--koreader',str(a.koreader),
              '--candidate',str(a.candidate),'--width',str(a.width),'--height',str(a.height),'--dpi',str(a.dpi)]
        payload=dict(book=BOOK_ID,chapter='1',chapter_idx=1,first_offset=first,next_offset=first,source=source,
                     source_format='web_xhtml',chapters=CHAPTERS,book_version=7,ordinary=True,owner='900000',
                     cookies=dict(wr_vid='900000',wr_skey='synthetic-cookie-session'),armed=False,reconnect=True,reconnect_discover=True)
        child=subprocess.run(base,input=json.dumps(payload,ensure_ascii=False).encode(),stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,env=env,timeout=420)
        found=json.loads(child.stdout)
        if child.returncode or found.get('result')!='DISCOVERED':raise ValueError('mock/discovery')
        target=found['offset'];summary=source_summary(model,target)
        if target==first:raise ValueError('mock/target')
        payload.pop('reconnect_discover');payload.update(next_offset=target,expected_summary=summary,
                                                         ordinary_trial=dict(rpc_token=secrets.token_hex(16)))
        command=[sys.executable,str(Path(__file__).with_name('run_ordinary_reconnect_trial.py')),'--koreader',str(a.koreader),
                 '--candidate',str(a.candidate),'--width',str(a.width),'--height',str(a.height),'--dpi',str(a.dpi),
                 '--mock-port',str(server.server_port)]
        captured={};scope={};grant={'synthetic':'grant'};catalog={'synthetic':'catalog'}
        shelf={'synckey':100,'books':[{'bookId':'900002'},{'bookId':BOOK_ID,'readUpdateTime':100}],
               'bookProgress':[dict(bookId=BOOK_ID,chapterUid=1,chapterIdx=1,chapterOffset=first,progress=25,
                                    appId='synthetic-other-reader',updateTime=100,synckey=100,readingTime=0)]}
        def shelf_snapshot():
            result=deepcopy(shelf);posts=server.request_totals.get(('/web/book/read',''),0)
            if posts:
                result['synckey']+=posts
                target_row=result['books'].pop(1);target_row['readUpdateTime']+=posts;result['books'].insert(0,target_row)
                current=server.get_progress(BOOK_ID)['book'];item=result['bookProgress'][0]
                item.update(chapterUid=current['chapterUid'],chapterIdx=current['chapterIdx'],chapterOffset=current['chapterOffset'],
                            progress=current['progress'],appId=web_app_id(),updateTime=100+posts,synckey=100+posts)
            return result
        initial=dict(book_id=BOOK_ID,chapter_uid='1',chapter_idx=1,chapter_offset=first,raw_percent=25,summary='old summary')
        def check_context(html):
            context=reader_context(dict(book_id=BOOK_ID),html)
            if not same_position(reader_progress(dict(book=context['progress']),BOOK_ID),initial):raise ValueError('mock/context')
            fixed=context.get('pclts')
            if fixed is None or type(fixed) is str and fixed in ('','0') or type(fixed) is int and fixed==0:fixed=None
            scope.update(context=context,pclts=fixed)
            return True
        def check_body(value):
            if not isinstance(value,dict) or type(value.get('pr')) is not int or not 0<=value['pr']<=100:return False
            selected={key:'a'*64 for key in HASHES}
            selected['owner_sha256']=digest('900000')
            selected['grant_sha256']=digest(grant);selected['source_sha256']=hashlib.sha256(source.encode()).hexdigest()
            selected['catalog_sha256']=digest(catalog);selected['web_shelf_sha256']=digest(shelf);selected['native_shelf_sha256']=digest(shelf)
            if retry_mode:selected.update(web_shelf_core_sha256=state_hash(shelf),native_shelf_core_sha256=state_hash(shelf))
            selected.update(protocol=PROTOCOL,baseline=initial,target=dict(initial,chapter_offset=target,raw_percent=value['pr'],summary=summary),
                            counts=dict(readingTime=0,recordReadingTime=0,ttsTime=0),version=7)
            context=scope['context']
            validate_body(selected,context,scope['pclts'],'enter',value)
            captured.update(plan=selected,context=context,pclts=scope['pclts'])
            return True
        dry={};preview(command+['--dry'],payload,check_body,dry,check_context=check_context)
        if dry.get('result')!='READER_POSITION_DRY_VERIFIED' or server.request_totals.get(('/web/book/read',''),0)!=0:
            raise ValueError('mock/dry')
        store=(OrdinaryReconnectThirdStore if a.third_scope else OrdinaryReconnectRetryStore if retry_mode else OrdinaryReconnectStore)(Backend());store.reserve(captured['plan'])
        class LocalOpener:
            def __init__(self):self.opener=build_opener(ProxyHandler({}))
            def open(self,request,timeout):
                url='http://127.0.0.1:'+str(server.server_port)+'/__proxy?url='+quote(request.full_url,safe='')
                mapped=Request(url,data=request.data,headers=dict(request.header_items()),method=request.get_method())
                return self.opener.open(mapped,timeout=timeout)
        class LocalWeb(RestoreProbe):
            def verify_account(self):self.authenticated=True
            def inspect(self,identity):
                if identity!=BOOK_ID:raise ValueError('mock/book')
                if (a.retry_enter_read_failure and not getattr(self,'rejected_once',False)
                        and server.request_totals.get(('/web/book/read',''),0)==1):
                    self.rejected_once=True
                    with server.lock:server.control.update(match='/web/book/getProgress',status=503,times=1,skip=0)
                    WebSourceProbe.request(self,'progress_before',WEB+'/web/book/getProgress?bookId='+BOOK_ID)
                    raise ValueError('mock/read_failure_not_delivered')
                self.book_id=identity;self.raw_progress=server.get_progress(identity);self.catalog=catalog
                self.shards={'e_0':'a','e_1':'b','e_3':'c'};self.report['read_snapshot_consistent']=True
                self.reader={'psvts':'mock-session','token':DEFAULT_TOKEN,'pclts':0}
            def request(self,stage,url,body=None,**options):
                if stage!='shelf' or body is not None:raise ValueError('mock/read_scope')
                return shelf_snapshot()
        class LocalNative:
            def request(self,stage,url,body=None,credentials=None):
                if body is not None or credentials!=grant:raise ValueError('mock/read_scope')
                if stage=='ordinary_rpc_progress':
                    raw=server.get_progress(BOOK_ID);raw['book'].update(readingTime=0,recordReadingTime=0,ttsTime=0);return raw
                if stage=='ordinary_rpc_info':return dict(bookId=BOOK_ID,version=7)
                if stage=='ordinary_rpc_shelf':return shelf_snapshot()
                raise ValueError('mock/read_scope')
        web=LocalWeb(opener=LocalOpener());restore_web=RestoreProbe(opener=LocalOpener())
        for client in (web,restore_web):
            client.vid='900000';client.book_id=BOOK_ID;client.authenticated=True
            for key,value in payload['cookies'].items():client.set_cookie(key,value)
        payload.pop('ordinary_trial');report={}
        partial_report={};partial_recovered=False
        try:
            original_observe=ordinary_reconnect_live.observe
            def legacy_observe(web_arg,native_arg,grant_arg,plan_arg,expected,current,**options):
                if (a.partial_recovery or a.partial_recovery_noack) and expected==entered_point(plan_arg) and expected!=plan_arg['target']:
                    expected=plan_arg['target']
                return original_observe(web_arg,native_arg,grant_arg,plan_arg,expected,current,**options)
            with patch.object(ordinary_reconnect_observe,'decode_content_shards',return_value=source), \
                 patch.object(ordinary_reconnect_live,'observe',side_effect=legacy_observe):
                try:execute_trial(store,captured['plan'],payload,command,web,LocalNative(),grant,restore_web,lambda:True,report)
                except Exception:
                    if not (a.noack or a.restore_noack or a.partial_recovery or a.partial_recovery_noack or retry_recovery_mode or a.retry_restore_noack):raise
            if a.retry_restore_noack:
                if (report.get('result')!='UNVERIFIED' or not report.get('restore_claimed') or report.get('restore_acknowledged')
                        or store.read()[0]['phase']!='restore_pending' or server.request_totals.get(('/web/book/read',''),0)!=3):
                    raise ValueError('mock/restore_readback')
                import ordinary_partial_recovery as partial
                original_state,original_receipt=store.read()
                with patch.object(partial,'decode_content_shards',return_value=source):
                    recovered=checked_pair(web,LocalNative(),grant,captured['plan'],captured['plan']['baseline'],lambda:True)
                if (state_hash(recovered['web_shelf'])!=captured['plan']['web_shelf_core_sha256']
                        or state_hash(recovered['native_shelf'])!=captured['plan']['native_shelf_core_sha256']):
                    raise ValueError('mock/restore_readback')
                proof=(ThirdRestoreReadbackStore if a.third_scope else RestoreReadbackStore)(Backend())
                bridge=(ThirdRecoveryRenewalStore if a.third_scope else RetryRecoveryRenewalStore)(Backend());selected=captured['plan']
                proof.record(dict(original_intent_sha256=hashlib.sha256(original_receipt.pending).hexdigest(),owner_sha256=selected['owner_sha256'],
                    native_grant_sha256=digest(grant),renewal_bridge_sha256='0'*64,source_sha256=selected['source_sha256'],
                    catalog_sha256=selected['catalog_sha256'],web_shelf_core_sha256=selected['web_shelf_core_sha256'],
                    native_shelf_core_sha256=selected['native_shelf_core_sha256']))
                store.close_after_restore_readback(original_receipt,proof,bridge)
                if store.read()[0]['phase']!='restore_readback_confirmed' or server.request_totals.get(('/web/book/read',''),0)!=3:
                    raise ValueError('mock/restore_readback')
                partial_recovered=True
            elif a.partial_recovery or a.partial_recovery_noack or retry_recovery_mode:
                expected_posts=1 if a.retry_enter_noack or a.retry_enter_read_failure or not retry_recovery_mode else 2
                expected_phase='enter_pending' if a.retry_enter_noack else 'enter_acknowledged' if a.retry_enter_read_failure or not retry_recovery_mode else 'position_pending'
                if (captured['plan']['target']['raw_percent']==initial['raw_percent'] or report.get('result')!='UNVERIFIED'
                        or report['claimed_posts']!=expected_posts or report['acknowledged_posts']!=(0 if a.retry_enter_noack else 1)
                        or store.read()[0]['phase']!=expected_phase or server.request_totals.get(('/web/book/read',''),0)!=expected_posts):
                    raise ValueError('mock/partial_enter')
                if a.retry_enter_read_failure and (not getattr(web,'rejected_once',False)
                        or web.report['stages'][-1]!=dict(stage='progress_before',status=503)
                        or not any(event['path']=='/web/book/getProgress' and event['status']==503 for event in server.events)
                        or report.get('independently_verified')!=0 or report.get('restore_claimed') is not False):
                    raise ValueError('mock/read_failure')
                import ordinary_partial_recovery as partial
                original_state,original_receipt=store.read()
                recovery=(ThirdPartialRecoveryStore if a.third_scope else RetryPartialRecoveryStore if retry_recovery_mode else PartialRecoveryStore)(Backend())
                with patch.object(partial,'decode_content_shards',return_value=source):
                    expected=captured['plan']['target'] if retry_recovery_mode and not (a.retry_enter_noack or a.retry_enter_read_failure) else observed_point(captured['plan'])
                    observed=checked_pair(web,LocalNative(),grant,captured['plan'],expected,lambda:True)
                    bound=recovery_binding(original_receipt,observed,digest(grant),'0'*64,
                        observed_state=('entered' if a.retry_enter_noack or a.retry_enter_read_failure else 'target') if retry_recovery_mode else None,
                        original_phase=expected_phase if retry_recovery_mode else None)
                    recovery_receipt=recovery.reserve(bound)
                    server.control['progress_confirmation']='noack' if a.partial_recovery_noack or a.retry_recovery_noack else 'plain'
                    def factory(*args):
                        probe=RecoveryProbe(*args,opener=LocalOpener());probe.vid='900000';probe.book_id=BOOK_ID;probe.authenticated=True
                        for key,value in payload['cookies'].items():probe.set_cookie(key,value)
                        return probe
                    try:restore_once(store,original_receipt,recovery,recovery_receipt,web,LocalNative(),grant,captured['plan'],
                                     bound,lambda:True,factory,partial_report)
                    except Exception:
                        if not (a.partial_recovery_noack or a.retry_recovery_noack):raise
                if a.partial_recovery_noack or a.retry_recovery_noack:
                    if (partial_report.get('result')!='UNVERIFIED' or recovery.read()[0]['phase']!='pending'
                            or store.read()[0]['phase']!=expected_phase):raise ValueError('mock/partial_noack')
                elif (partial_report.get('result')!='ORDINARY_PARTIAL_RECOVERY_VERIFIED'
                        or recovery.read()[0]['phase']!='retired'
                        or store.read()[0]['phase']!=('partial_restored_after_position' if retry_recovery_mode and not (a.retry_enter_noack or a.retry_enter_read_failure) else 'partial_restored')):
                    raise ValueError('mock/partial_recovery')
                if server.request_totals.get(('/web/book/read',''),0)!=expected_posts+1:raise ValueError('mock/partial_count')
                partial_recovered=not (a.partial_recovery_noack or a.retry_recovery_noack)
                if partial_recovered:
                    final=server.get_progress(BOOK_ID)
                    if not same_position(reader_progress(final,BOOK_ID),initial) or final['book'].get('summary')!=initial['summary']:
                        raise ValueError('mock/partial_readback')
        finally:web.close();restore_web.close()
        if a.partial_recovery or a.partial_recovery_noack or retry_recovery_mode or a.retry_restore_noack:
            pass
        elif a.noack:
            if (report.get('result')!='UNVERIFIED' or report['claimed_posts']!=2 or report['acknowledged_posts']!=1
                    or store.read()[0]['phase']!='position_pending' or server.request_totals.get(('/web/book/read',''),0)!=2):
                raise ValueError('mock/noack')
        elif a.restore_noack:
            if (report.get('result')!='UNVERIFIED' or report['claimed_posts']!=2 or report['acknowledged_posts']!=2
                    or report.get('restore_claimed') is not True or report.get('restore_acknowledged') is not False
                    or store.read()[0]['phase']!='restore_pending' or server.request_totals.get(('/web/book/read',''),0)!=3):
                raise ValueError('mock/restore_noack')
        elif (report.get('result')!='ORDINARY_RECONNECT_TRIAL_VERIFIED' or store.read()[0]['phase']!='retired'
                or server.request_totals.get(('/web/book/read',''),0)!=3):raise ValueError('mock/restore')
        if a.preserve_position_percent and report.get('position_percent_modes')!=['preserved','preserved']:
            raise ValueError('mock/percent')
        restored=partial_recovered if a.partial_recovery or a.partial_recovery_noack or retry_recovery_mode or a.retry_restore_noack else not (a.noack or a.restore_noack)
        print(json.dumps(dict(result='PASS',mock_only=True,noack=a.noack,restore_noack=a.restore_noack,dry_body_bound=True,dry_posts=0,
                              claimed_posts=report['claimed_posts'],acknowledged_posts=report['acknowledged_posts'],
                              verified=report['independently_verified'],coordinator=True,actual_reader=True,
                              retry_scope=retry_mode,third_scope=a.third_scope,partial_recovery=a.partial_recovery or a.partial_recovery_noack or retry_recovery_mode,retry_recovery=retry_recovery_mode,
                              recovery_noack=a.partial_recovery_noack or a.retry_recovery_noack,read_failure_after_enter=a.retry_enter_read_failure,
                              enter_noack=a.retry_enter_noack,restore_readback_resolved=a.retry_restore_noack,restore_verified=restored,
                              position_percent_modes=report.get('position_percent_modes'),real_account_posts=0)))
    finally:server.shutdown();server.server_close();thread.join()

if __name__=='__main__':main()
