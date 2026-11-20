#!/usr/bin/env python3
"""One scoped real native CB-position round trip; offline unless requested."""
import argparse
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import resource
import secrets
import subprocess
import tempfile

from cb_cloud_position import observed
from cb_existing_position_intent import Intent
from cb_existing_position_transport import target_observation
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,MacKeychain,SessionStore
from verify_cb_cloud_position import Web
from verify_cb_existing_position_trial import choose
from verify_cb_full_summary_payload import compare
from verify_cb_progress import cb_ids
from verify_position_roundtrip import DEFAULT_TOKEN,canonical
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE,WebSourceProbe

SERVICE='org.codex.weread.cb-existing-native-position-v1'


def intent_store():
    path=Path(tempfile.gettempdir())/('codex-cb-existing-native-position-'+ACCOUNT+'.lock')
    return Intent(backend=MacKeychain(service=SERVICE,account=ACCOUNT),lock=lambda:project_lock(path))


class NativeFailure(ValueError):
    def __init__(self,writes,reads):
        self.writes=writes if type(writes) is int and 0<=writes<=2 else None
        self.reads=reads if type(reads) is int and 0<=reads<=1 else None
        super().__init__('cb_native/unconfirmed')


def native(command,position,context,cookies,mode,*,synthetic=False):
    payload=dict(position=position,context=context,cookies=cookies,mode=mode,synthetic=synthetic)
    raw=json.dumps(payload,ensure_ascii=False).encode()
    if len(raw)>65536:raise ValueError('cb_native/input')
    child=subprocess.run(command,input=raw,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=90)
    marker=b'\nWEREAD_CB_EXISTING_NATIVE_REPORT='
    if len(child.stdout)>65536 or child.stdout.count(marker)!=1:raise NativeFailure(None,None)
    result=json.loads(child.stdout.split(marker,1)[1].splitlines()[0])
    expected=dict(accepted=True,acknowledged=True,confirmed=True,writes=2 if mode=='both' else 1,reads=1,
                  enter_attempted=mode=='both',report_attempted=True)
    if child.returncode or result!=expected:raise NativeFailure(result.get('writes'),result.get('reads'))
    return expected


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true');parser.add_argument('--apply',action='store_true')
    parser.add_argument('--source-path',default='/source');parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if args.apply and not args.saved_session or args.saved_session and not args.lua_command:
        parser.error('online operation requires saved session and Lua command')
    if args.lua_command and not args.saved_session:parser.error('Lua command requires saved session')
    report=dict(result='OFFLINE_ONLY',account_data_writes=0,max_writes_allocated=0,authentication_writes=0,
                private_data_in_report=False,no_replay=True,position_unchanged=None,shelf_order_unchanged=None)
    if not args.saved_session:
        print(json.dumps(report));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    saved=web=check=after=None;book=chapters=baseline=None;phase='session'
    try:
        store=SessionStore();saved=store.load();web=Web();web.vid=saved['vid']
        for k,v in saved['cookies'].items():web.set_cookie(k,v)
        web.verify_account();shelf=web.request('shelf',BASE+'/web/shelf/sync');ids=cb_ids(shelf);web.allowed=set(ids)
        shelf_ids=[str(row['bookId']) for row in shelf['books']]
        phase='source';plan=models=None
        for book in ids:
            sample=web.inspect(book);raw=web.progress[(book,'progress_before')];candidate=choose(sample,raw)
            if candidate:
                plan,models=candidate;chapters=sample['chapters'];baseline=observed(raw,book,chapters,'web');break
        if plan is None:raise ValueError('cb_native/no_sample')
        compare(models,[*args.lua_command,args.source_path+'/spec/koreader/cb_full_summary_payload_probe.lua',args.source_path])
        web.verify_account()
        if save_refreshed_web_session(store,saved,web):
            previous=saved;saved=store.load()
            if saved['vid']!=previous['vid']:raise ValueError('cb_native/owner')
            previous.clear()
        command=[*args.lua_command,args.source_path+'/spec/koreader/cb_existing_position_report_probe.lua',args.source_path]
        report.update(result='READ_ONLY_READY',lua_payloads_compared=4,source_verified=True)
        check=WebSourceProbe();check.vid=saved['vid'];check.book_id=book;check.chapter=sample['chapter_uid']
        for k,v in saved['cookies'].items():check.set_cookie(k,v)
        check.verify_account()
        def current():
            return observed(check.request('progress_after',BASE+'/web/book/getProgress?bookId='+book),book,chapters,'web')
        def refreshed():
            nonlocal saved
            if save_refreshed_web_session(store,saved,check):
                previous=saved;saved=store.load()
                if saved['vid']!=previous['vid']:raise ValueError('cb_native/owner')
                previous.clear()
        if current()!=baseline:raise ValueError('cb_native/baseline')
        refreshed()
        if args.apply:
            phase='reserve';intent=intent_store()
            reservation=intent.reserve(saved['vid'],book,secrets.token_hex(16),hashlib.sha256(canonical(baseline).encode()).hexdigest())
            context=dict(book_id=book,psvts=plan['context']['psvts'],pclts=plan['pclts'],
                         token=plan['context'].get('token') or DEFAULT_TOKEN)
            target=target_observation(baseline,plan['target']['chapter_offset'])
            before=baseline
            for mode,stages,key,point,expected in (
                ('both',('write_enter','write_same'),'same',plan['baseline'],baseline),
                ('report',('write_probe',),'advanced',plan['target'],target),
                ('report',('write_restore',),'restored',plan['baseline'],baseline)):
                phase=key
                if current()!=before:raise ValueError('cb_native/concurrent')
                refreshed()
                for stage in stages:
                    receipt=intent.claim(reservation,stage);report['max_writes_allocated']+=1
                    if not intent.verify(reservation,receipt):raise ValueError('cb_native/authority')
                position=dict(book_id=book,chapter_uid=str(point['chapter_uid']),chapter_idx=point['chapter_idx'],
                    chapter_offset=point['chapter_offset'],percent=point['raw_percent'],summary=point['summary'])
                try:result=native(command,position,context,saved['cookies'],mode)
                except NativeFailure as error:
                    if error.writes is not None:report['account_data_writes']+=error.writes
                    report['writes_uncertain']=True;raise
                report['account_data_writes']+=result['writes']
                if current()!=expected:raise ValueError('cb_native/observation')
                report[key]=True;before=expected
            report['result']='TRIAL_COMPLETE'
        phase='after';refreshed();after=WebSourceProbe();after.vid=saved['vid'];after.book_id=book;after.chapter=sample['chapter_uid']
        for k,v in saved['cookies'].items():after.set_cookie(k,v)
        after.verify_account();latest=after.request('progress_after',BASE+'/web/book/getProgress?bookId='+book)
        report['position_unchanged']=observed(latest,book,chapters,'web')==baseline
        final_shelf=after.request('shelf',BASE+'/web/shelf/sync');after.verify_account()
        report['shelf_order_unchanged']=[str(row['bookId']) for row in final_shelf['books']]==shelf_ids
        if not report['position_unchanged'] or not report['shelf_order_unchanged']:report['result']='UNVERIFIED'
    except Exception:
        report.update(result='UNVERIFIED',failure_stage=phase)
        if check and saved and baseline and after is None:
            try:
                after=WebSourceProbe();after.vid=saved['vid'];after.book_id=book;after.chapter=sample['chapter_uid']
                for k,v in saved['cookies'].items():after.set_cookie(k,v)
                after.verify_account();latest=after.request('progress_after',BASE+'/web/book/getProgress?bookId='+book)
                report['position_unchanged']=observed(latest,book,chapters,'web')==baseline
                final_shelf=after.request('shelf',BASE+'/web/shelf/sync');after.verify_account()
                report['shelf_order_unchanged']=[str(row['bookId']) for row in final_shelf['books']]==shelf_ids
            except Exception:pass
    finally:
        if web:
            if not check and saved and web.authenticated:
                try:save_refreshed_web_session(store,saved,web)
                except Exception:report['result']='UNVERIFIED'
            web.samples.clear();web.progress.clear();web.close()
        if check:
            if not after and saved and check.authenticated:
                try:save_refreshed_web_session(store,saved,check)
                except Exception:report['result']='UNVERIFIED'
            check.close()
        if after:
            if saved and after.authenticated:
                try:save_refreshed_web_session(store,saved,after)
                except Exception:report['result']='UNVERIFIED'
            after.close()
        if saved:saved.clear()
    print(json.dumps(report));return int(report['result'] not in ('READ_ONLY_READY','TRIAL_COMPLETE'))


if __name__=='__main__':raise SystemExit(main())
