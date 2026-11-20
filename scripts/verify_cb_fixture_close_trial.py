#!/usr/bin/env python3
"""One fresh fixture, two scoped native close round trips, exact cleanup."""
import argparse
import hashlib
import json
from pathlib import Path
import resource
import subprocess
import tempfile

from cb_cloud_position import state
from cb_fixture_close_intent import Intent as UiIntent
from cb_fixture_position import plan as position_plan
from cb_fixture_position_intent import Intent as SeedIntent
from cb_fixture_position_transport import Probe as PositionProbe
from secure_native_session import NativeSessionStore,project_lock
from secure_weread_session import ACCOUNT,MacKeychain,SessionStore
from synthetic_epub_trial import Journal
from synthetic_upload_epub import TEXT
from verify_cb_cloud_position import Web
from verify_cb_fixture_position_trial import owned
from verify_cb_reading import CbReadingProbe
from verify_cb_source_currentness import descriptor
from verify_personal_upload_trial import Probe as UploadProbe
from verify_synthetic_epub_upload import run as run_upload
from verify_source_coordinates import FilteredSource
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE,WebSourceProbe

UPLOAD_SERVICE='org.codex.weread.cb-close-fixture-upload-v1'
SEED_SERVICE='org.codex.weread.cb-close-fixture-seed-v1'
UI_SERVICE='org.codex.weread.cb-close-fixture-ui-v1'


def backend(service):return MacKeychain(service=service,account=ACCOUNT)
def lock(name):
    path=Path(tempfile.gettempdir())/('codex-cb-close-fixture-'+name+'-'+ACCOUNT+'.lock')
    return lambda:project_lock(path)
def stores():
    return (Journal(backend=backend(UPLOAD_SERVICE),lock=lock('upload')),
            SeedIntent(backend=backend(SEED_SERVICE),lock=lock('seed')),
            UiIntent(backend=backend(UI_SERVICE),lock=lock('ui')))


def ui_runner(command,payload,width,height,dpi):
    child=subprocess.run([*command,'--width',str(width),'--height',str(height),'--dpi',str(dpi)],
        input=json.dumps(payload,ensure_ascii=False).encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=420)
    if len(child.stdout)>4096:raise ValueError('fixture_manual/ui')
    try:result=json.loads(child.stdout)
    except Exception:raise ValueError('fixture_manual/ui') from None
    expected=dict(result='PASS',profile_removed=True,installed_bytes_match=True,native_choice=True,actual_source=True,
        upload_confirmed=True,fresh_process=True,pending_cleared=True,journal_cleared=True,automatic_disabled=False,close_verified=True,
        writes=3,denied=0,credentials_not_persisted=True)
    if child.returncode or result!=expected:raise ValueError('fixture_manual/ui')
    return True


def run(saved,store,native,grant,journal,seed_intent,ui_intent,runner,*,apply=False,upload_factory=UploadProbe,upload_run=run_upload):
    report=dict(result='UNVERIFIED',phase='preflight',account_data_writes_known=0,ui_writes_allocated=0,
        authentication_writes=0,fixture_only=True,private_data_in_report=False,existing_book_writes=0,stages=[])
    current={'saved':saved,'plan':None,'source_hash':None,'source_verified':False,'seed':None}
    def same_grant(value):return native.load(current['saved']['vid'])==value
    def persist(probe):
        if probe.authenticated and save_refreshed_web_session(store,current['saved'],probe):
            previous=current['saved'];current['saved']=store.load()
            if current['saved']['vid']!=previous['vid']:raise ValueError('fixture_manual/owner')
            previous.clear()
    def connect(cls,target):
        probe=cls();probe.vid=current['saved']['vid']
        if hasattr(probe,'allowed'):probe.allowed={target}
        for key,value in current['saved']['cookies'].items():probe.set_cookie(key,value)
        probe.verify_account();return probe
    def read_source(target):
        web=connect(CbReadingProbe,target)
        try:
            sample=web.inspect(target);web.verify_account()
            valid=(sample['book_id']==target and sample['source_format']=='web_xhtml' and TEXT in sample['source']
                and set(web.last_checks)=={'catalog_unchanged','versions_unchanged','position_unchanged'}
                and all(value is True for value in web.last_checks.values()))
            if valid:
                current['plan']=position_plan(target,sample);current['source_hash']=sample['source_raw_sha256']
            current['source_verified']=valid;return valid
        finally:persist(web);web.samples.clear();web.close()
    def trial(upload_journal,receipt,_upload_plan,target):
        if not current['source_verified'] or not current['plan']:return True
        owner=current['saved']['vid']
        if not owned(upload_journal,receipt,target,owner,grant,same_grant):return False
        upload_state,_=upload_journal.read();attempt=upload_state['attempt']
        seed_receipt=seed_intent.reserve(owner,target,attempt)
        def authority():
            return owned(upload_journal,receipt,target,owner,grant,same_grant) and seed_intent.verify(seed_receipt,owner,target,attempt)
        seed=PositionProbe(current['plan'],owner,authority)
        try:
            for key,value in current['saved']['cookies'].items():seed.set_cookie(key,value)
            seed.verify_account();current['seed']=seed.execute(dict(chapter_uid=0,chapter_offset=0,raw_percent=0))
            report['account_data_writes_known']+=current['seed']['writes']
            if current['seed']['result']!='PASS':return False
        finally:persist(seed);seed.close()
        source=connect(Web,target)
        try:
            sample=source.inspect(target);raw=source.progress[(target,'progress_before')]
            point=state(raw,target,sample['chapters'],'web');checked=descriptor(sample,point)
            if (not checked or sample['source_raw_sha256']!=current['source_hash'] or sample['chapter_uid']!=current['plan']['chapter']
                    or point['chapter_offset']!=current['plan']['first'] or checked['chapter_idx']!=current['plan']['index']):
                return False
            source.verify_account();persist(source)
            chapters=[]
            for row in sample['chapters']:
                item=dict(row)
                if type(item.get('wordCount')) not in (int,float) or item['wordCount']<=0:item['wordCount']=1000
                chapters.append(item)
            model=FilteredSource(sample['source'],allow_multiple_bodies=True)
            source_text=sample['source']
        finally:source.samples.clear();source.progress.clear();source.close()
        baseline=current['plan']['first'];following=current['plan']['following']
        if not authority():return False
        baseline_digest=hashlib.sha256((current['source_hash']+':'+str(baseline)).encode()).hexdigest()
        reservation=ui_intent.reserve(owner,target,attempt,baseline_digest)
        for index,(before,after,width,height,dpi,stages) in enumerate((
            (baseline,following,600,800,167,('first_enter','first_manual','first_close')),
            (baseline,following,1264,1680,300,('second_enter','second_manual','second_close')))):
            if not authority():return False
            read=connect(WebSourceProbe,target);read.book_id=target;read.chapter=sample['chapter_uid']
            try:
                before_raw=read.request('progress_after',BASE+'/web/book/getProgress?bookId='+target)
                before_point=state(before_raw,target,chapters,'web')
                if before_point.get('kind')!='located' or before_point['chapter_offset']!=before:return False
                persist(read)
            finally:read.close()
            expected_summary=''.join(c for c in model.anchor_at(after,size=96) if not c.isspace())[:20]
            if not expected_summary:return False
            for stage in stages:
                permit=ui_intent.claim(reservation,stage);report['ui_writes_allocated']+=1
                if not ui_intent.verify(reservation,permit):return False
            payload=dict(book=target,chapter=sample['chapter_uid'],chapter_idx=checked['chapter_idx'],first_offset=before,
                next_offset=after,expected_summary=expected_summary,source=source_text,chapters=chapters,book_version=0,close=True,
                timer_summary=''.join(c for c in model.anchor_at(before,size=96) if not c.isspace())[:20],
                owner=current['saved']['vid'],cookies=current['saved']['cookies'])
            try:
                ui_runner(runner,payload,width,height,dpi)
                report['account_data_writes_known']+=3
            except Exception:
                report['ui_writes_uncertain']=True;return False
            read=connect(WebSourceProbe,target);read.book_id=target;read.chapter=sample['chapter_uid']
            try:
                after_raw=read.request('progress_after',BASE+'/web/book/getProgress?bookId='+target)
                final=state(after_raw,target,chapters,'web')
                if (final.get('kind')!='located' or final['chapter_uid']!=sample['chapter_uid']
                        or final['chapter_idx']!=checked['chapter_idx'] or final['chapter_offset']!=before
                        or not final['summary_present'] or final['summary']!=payload['timer_summary']):return False
                persist(read)
            finally:read.close()
            report['stages'].append(dict(screen='600x800' if index==0 else '1264x1680',native_choice=True,close_confirmed=True,
                upload_confirmed=True,independent_readback=True,fresh_offline_reopen=True,credentials_not_persisted=True))
        return authority() and len(report['stages'])==2
    try:
        if seed_intent.backend.load() is not None or ui_intent.backend.load() is not None:
            raise ValueError('fixture_manual/already_reserved')
        web=connect(CbReadingProbe,None)
        try:web.verify_account();persist(web)
        finally:web.close()
        upload=upload_factory(journal,same_grant)
        result=upload_run(upload,journal,grant,same_grant,read_source,apply=apply,cleanup_gate=trial)
        report['upload']=result;report['phase']=result.get('phase','unknown')
        report['account_data_writes_known']+=result.get('cos_put_attempts',0)+result.get('notify_posts',0)+result.get('cleanup_posts',0)
        if result.get('result')=='READ_ONLY_PREVIEW':report['result']='READ_ONLY_PREVIEW'
        elif result.get('result')=='EPUB_IMPORT_AND_SOURCE_VERIFIED' and len(report['stages'])==2:
            report['result']='FIXTURE_CLOSE_SYNC_VERIFIED'
    except Exception:
        report['result']='UNVERIFIED'
    finally:
        current['plan']=None
        if current['saved'] is not saved and saved:saved.clear()
        if current['saved']:current['saved'].clear()
    return report


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true');parser.add_argument('--apply',action='store_true')
    parser.add_argument('--runner',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    if args.apply and not args.saved_session or args.saved_session and not args.runner:parser.error('saved session and runner required')
    if args.runner and not args.saved_session:parser.error('runner requires saved session')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY',account_data_writes_known=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=None
    try:
        store=SessionStore();saved=store.load();native=NativeSessionStore();grant=native.load(saved['vid'])
        report=run(saved,store,native,grant,*stores(),args.runner,apply=args.apply)
    except Exception:report=dict(result='UNVERIFIED',account_data_writes_known=0)
    finally:
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(report));return int(report['result'] not in ('READ_ONLY_PREVIEW','FIXTURE_CLOSE_SYNC_VERIFIED'))


if __name__=='__main__':raise SystemExit(main())
