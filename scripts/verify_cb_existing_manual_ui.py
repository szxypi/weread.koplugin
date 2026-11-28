#!/usr/bin/env python3
"""One scoped existing-book ReaderUI round trip with exact original restoration."""
import argparse
from copy import deepcopy
import hashlib
import json
import math
from pathlib import Path
import resource
import secrets
import tempfile

from cb_cloud_position import observed,state
from cb_existing_position_intent import Intent as UiIntent
from cb_manual_restore_intent import Intent as RestoreIntent
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,MacKeychain,SessionStore
from verify_cb_cloud_position import Web
from verify_cb_existing_position_trial import choose
from verify_cb_fixture_manual_trial import ui_runner
from verify_cb_full_summary_payload import compare
from verify_cb_native_position_trial import native
from verify_cb_progress import cb_ids
from verify_position_roundtrip import DEFAULT_TOKEN,canonical
from verify_source_coordinates import FilteredSource
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE,WebSourceProbe

UI_SERVICE='org.codex.weread.cb-existing-manual-ui-v1'


def ui_store():
    path=Path(tempfile.gettempdir())/('codex-cb-existing-manual-ui-'+ACCOUNT+'.lock')
    return UiIntent(backend=MacKeychain(service=UI_SERVICE,account=ACCOUNT),lock=lambda:project_lock(path))


def expected_step(original,actual,offset,summary):
    """Allow only the selected coordinate, its source summary and integer percent to change."""
    if not isinstance(actual,dict) or actual.get('state',{}).get('kind')!='located':return False
    percent=actual['state'].get('raw_percent')
    if type(percent) not in (int,float) or not math.isfinite(percent) or percent!=int(percent) or not 0<=percent<=100:return False
    expected=deepcopy(original)
    expected['state'].update(chapter_offset=offset,summary=summary,raw_percent=percent)
    expected['projection'].update(chapter_offset=offset,summary=summary,raw_percent=percent)
    return expected==actual


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true');parser.add_argument('--apply',action='store_true')
    parser.add_argument('--lua-command-json');parser.add_argument('--source-path',default='/source')
    parser.add_argument('--runner',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    if args.apply and not args.saved_session or args.saved_session and (not args.runner or not args.lua_command_json):
        parser.error('online operation requires session, runner and Lua command')
    if (args.runner or args.lua_command_json) and not args.saved_session:parser.error('online options require saved session')
    report=dict(result='OFFLINE_ONLY',account_data_writes_known=0,ui_writes_allocated=0,restore_writes_allocated=0,
        authentication_writes=0,private_data_in_report=False,no_replay=True,position_restored=None,shelf_order_unchanged=None,stages=[])
    if not args.saved_session:
        print(json.dumps(report));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    saved=web=None;book=chapters=baseline=None;phase='session'
    ui_intent=restore_intent=restore_record=None;sample=plan=None;shelf_ids=None
    try:
        command=json.loads(args.lua_command_json)
        if not isinstance(command,list) or not command or any(not isinstance(v,str) or not v for v in command):raise ValueError('cb_manual_ui/command')
        store=SessionStore();saved=store.load();web=Web();web.vid=saved['vid']
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();shelf=web.request('shelf',BASE+'/web/shelf/sync');ids=cb_ids(shelf);web.allowed=set(ids)
        shelf_ids=[str(row['bookId']) for row in shelf['books']]
        phase='source'
        for book in ids:
            sample=web.inspect(book);raw=web.progress[(book,'progress_before')];candidate=choose(sample,raw)
            if candidate:
                plan,models=candidate;chapters=sample['chapters'];baseline=observed(raw,book,chapters,'web');break
        if not plan:raise ValueError('cb_manual_ui/no_sample')
        source_hash=sample['source_raw_sha256'];source=sample['source'];uid=sample['chapter_uid']
        model=FilteredSource(source,allow_multiple_bodies=True)
        start,following=plan['baseline']['chapter_offset'],plan['target']['chapter_offset']
        summaries={offset:''.join(c for c in model.anchor_at(offset,size=96) if not c.isspace())[:20] for offset in (start,following)}
        if any(not value for value in summaries.values()):raise ValueError('cb_manual_ui/summary')
        compare(models,[*command,args.source_path+'/spec/koreader/cb_full_summary_payload_probe.lua',args.source_path])
        web.verify_account()
        def persist(probe):
            nonlocal saved
            if store.load()!=saved:raise ValueError('cb_manual_ui/session_changed')
            if save_refreshed_web_session(store,saved,probe):
                previous=saved;saved=store.load()
                if saved['vid']!=previous['vid']:raise ValueError('cb_manual_ui/owner')
                previous.clear()
        persist(web);web.samples.clear();web.progress.clear();web.close();web=None
        def read_current(include_shelf=False):
            probe=WebSourceProbe();probe.vid=saved['vid'];probe.book_id=book;probe.chapter=uid
            try:
                for key,value in saved['cookies'].items():probe.set_cookie(key,value)
                probe.verify_account();value=observed(probe.request('progress_after',BASE+'/web/book/getProgress?bookId='+book),book,chapters,'web')
                shelves=probe.request('shelf',BASE+'/web/shelf/sync') if include_shelf else None
                probe.verify_account();persist(probe)
                return value,shelves
            finally:probe.close()
        if read_current()[0]!=baseline:raise ValueError('cb_manual_ui/baseline_changed')
        report.update(result='READ_ONLY_READY',source_verified=True,lua_payloads_compared=4)
        if args.apply:
            phase='reservation';ui_intent=ui_store();restore_intent=RestoreIntent()
            if ui_intent.backend.load() is not None or restore_intent.backend.load() is not None:
                raise ValueError('cb_manual_ui/already_reserved')
            attempt=secrets.token_hex(16);fingerprint=hashlib.sha256(canonical(baseline).encode()).hexdigest()
            ui_record=ui_intent.reserve(saved['vid'],book,attempt,fingerprint)
            restore_record=restore_intent.reserve(saved['vid'],book,attempt,fingerprint)
            local_chapters=[]
            for row in chapters:
                item=dict(row)
                if type(item.get('wordCount')) not in (int,float) or item['wordCount']<=0:item['wordCount']=1000
                local_chapters.append(item)
            previous=baseline
            for before,target,width,height,dpi,slots in (
                (start,following,600,800,167,('write_enter','write_same')),
                (following,start,1264,1680,300,('write_probe','write_restore'))):
                phase='ui_first' if before==start else 'ui_second'
                if read_current()[0]!=previous:raise ValueError('cb_manual_ui/concurrent')
                for stage in slots:
                    receipt=ui_intent.claim(ui_record,stage);report['ui_writes_allocated']+=1
                    if not ui_intent.verify(ui_record,receipt):raise ValueError('cb_manual_ui/authority')
                payload=dict(book=book,chapter=uid,chapter_idx=plan['baseline']['chapter_idx'],first_offset=before,
                    next_offset=target,expected_summary=summaries[target],source=source,chapters=local_chapters,book_version=0,
                    owner=saved['vid'],cookies=saved['cookies'])
                try:ui_runner(args.runner,payload,width,height,dpi)
                except Exception:
                    report['ui_writes_uncertain']=True;raise
                report['account_data_writes_known']+=2
                current,_shelf=read_current()
                if not expected_step(baseline,current,target,summaries[target]):raise ValueError('cb_manual_ui/readback')
                previous=current
                report['stages'].append(dict(screen='600x800' if width==600 else '1264x1680',native_choice=True,
                    upload_confirmed=True,independent_readback=True,fresh_offline_reopen=True,credentials_not_persisted=True))
            phase='restore_context'
            refreshed=Web();refreshed.vid=saved['vid'];refreshed.allowed={book}
            try:
                for key,value in saved['cookies'].items():refreshed.set_cookie(key,value)
                refreshed.verify_account();current_sample=refreshed.inspect(book)
                latest=observed(refreshed.progress[(book,'progress_before')],book,chapters,'web')
                if latest!=previous or current_sample['source_raw_sha256']!=source_hash or current_sample['chapter_uid']!=uid:
                    raise ValueError('cb_manual_ui/changed_before_restore')
                refreshed.verify_account();persist(refreshed)
                context=current_sample['context']
                pc=context.get('pclts')
                if pc is None or str(pc) in ('','0'):pc=plan['pclts']
                context=dict(book_id=book,psvts=context['psvts'],pclts=pc,token=context.get('token') or DEFAULT_TOKEN)
            finally:refreshed.samples.clear();refreshed.progress.clear();refreshed.close()
            if read_current()[0]!=previous:raise ValueError('cb_manual_ui/concurrent_before_restore')
            phase='restore'
            receipt=restore_intent.claim(restore_record);report['restore_writes_allocated']=1
            if not restore_intent.verify(restore_record,receipt):raise ValueError('cb_manual_ui/restore_authority')
            original=plan['baseline']
            position=dict(book_id=book,chapter_uid=str(original['chapter_uid']),chapter_idx=original['chapter_idx'],
                chapter_offset=original['chapter_offset'],percent=original['raw_percent'],summary=original['summary'])
            try:native([*command,args.source_path+'/spec/koreader/cb_existing_position_report_probe.lua',args.source_path],
                position,context,saved['cookies'],'report')
            except Exception:
                report['restore_write_uncertain']=True;raise
            report['account_data_writes_known']+=1
            if read_current()[0]!=baseline:raise ValueError('cb_manual_ui/restore_mismatch')
            report['result']='MANUAL_UI_ROUNDTRIP_VERIFIED'
        phase='after';last,shelves=read_current(include_shelf=True)
        report['position_restored']=last==baseline
        report['shelf_order_unchanged']=[str(row['bookId']) for row in shelves['books']]==shelf_ids
        if not report['position_restored'] or not report['shelf_order_unchanged']:report['result']='UNVERIFIED'
    except Exception:
        report.update(result='UNVERIFIED',failure_stage=phase)
        # Never repeat an uncertain send. Only report the independently observed
        # original state; the reserved restoration slot remains consumed or held.
        if saved and baseline and book:
            probe=None
            try:
                probe=WebSourceProbe();probe.vid=saved['vid'];probe.book_id=book;probe.chapter=sample['chapter_uid']
                for key,value in saved['cookies'].items():probe.set_cookie(key,value)
                probe.verify_account();last=observed(probe.request('progress_after',BASE+'/web/book/getProgress?bookId='+book),book,chapters,'web')
                shelves=probe.request('shelf',BASE+'/web/shelf/sync');probe.verify_account()
                report['position_restored']=last==baseline
                report['shelf_order_unchanged']=[str(row['bookId']) for row in shelves['books']]==shelf_ids
                if store.load()==saved and save_refreshed_web_session(store,saved,probe):
                    previous=saved;saved=store.load();previous.clear()
            except Exception:pass
            finally:
                if probe:probe.close()
    finally:
        if web:
            if saved and web.authenticated:
                try:
                    if store.load()==saved:save_refreshed_web_session(store,saved,web)
                except Exception:report['result']='UNVERIFIED'
            web.samples.clear();web.progress.clear();web.close()
        if saved:saved.clear()
    print(json.dumps(report));return int(report['result'] not in ('READ_ONLY_READY','MANUAL_UI_ROUNDTRIP_VERIFIED'))


if __name__=='__main__':raise SystemExit(main())
