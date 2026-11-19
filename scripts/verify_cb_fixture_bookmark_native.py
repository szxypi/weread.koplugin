#!/usr/bin/env python3
"""One fresh CB fixture, native bookmark save/delete and independent host readbacks.

Offline by default. Apply creates one self-authored fixture, first blocks the
native write as a dry run, then reserves two one-shot native writes. Unknown
effects retain the exact fixture and intent; neither process may replay them.
"""
import argparse
from functools import partial
import json
from pathlib import Path
import resource
import secrets
import subprocess
import tempfile

from cb_fixture_bookmark_trial import Intent as BaseIntent, prepare
from bookmark_trial_model import observe
from bookmark_point import from_mark
from native_trial_pipe import Frames, reply, stop, write_initial
from secure_native_session import NativeSessionStore, project_lock
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from reading_epub_trial import Journal,check as check_reading,prepare as prepare_reading
from synthetic_upload_epub import TEXT,build_reading
from verify_cb_fixture_highlight_trial import ScopedNative
from verify_cb_fixture_position_trial import owned
from verify_cb_progress import cb_id
from verify_cb_reading import CbReadingProbe
from verify_personal_upload_trial import Probe as UploadProbe
from verify_synthetic_epub_upload import run as upload_run
from verify_translation_preflight import save_refreshed_web_session

UPLOAD_SERVICE='org.codex.weread.cb-native-bookmark-upload-v2'
INTENT_SERVICE='org.codex.weread.cb-native-bookmark-intent-v2'
reading_upload=partial(upload_run,fixture_builder=build_reading,prepare_plan=prepare_reading,check_plan=check_reading)


class TrialFailure(ValueError):
    def __init__(self,stage):
        super().__init__('cb_native_bookmark/runner');self.stage=stage


def stores():
    def backend(service): return MacKeychain(service=service, account=ACCOUNT)
    def lock(name):
        path=Path(tempfile.gettempdir())/('codex-cb-native-bookmark-'+name+'-'+ACCOUNT+'.lock')
        return lambda:project_lock(path)
    return Journal(backend=backend(UPLOAD_SERVICE),lock=lock('upload')),BaseIntent(backend=backend(INTENT_SERVICE),lock=lock('intent'))


class Observer(ScopedNative):
    def __init__(self,*args,**kwargs):
        super().__init__(*args,max_gets=80,**kwargs)

    def request(self,stage,url,body=None,credentials=None,timeout=15):
        if body is not None:raise ValueError('cb_native_bookmark/host_write_forbidden')
        return super().request(stage,url,body,credentials,timeout)


def run_ui(command,payload,plan,body,baseline,intent,authority,read,*,armed=False):
    if type(armed) is not bool or not command or any(not isinstance(v,str) or not v for v in command):
        raise ValueError('cb_native_bookmark/command')
    if intent.read()!=(None,None) or not authority() or read()!=baseline:raise ValueError('cb_native_bookmark/preflight')
    value=dict(payload,armed=armed,token=secrets.token_hex(16));receipt=intent.reserve(plan) if armed else None
    child=None;steps=0;target=None
    try:
        child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
        write_initial(child.stdin,value);frames=Frames(child.stdout,value['token'],timeout=600)
        while True:
            kind,event=frames.next()
            if kind=='RESULT':
                result=event;break
            if not authority():raise ValueError('cb_native_bookmark/ownership')
            if not armed:
                if steps or event!={'seq':0,'preview':body} or read()!=baseline:raise ValueError('cb_native_bookmark/dry')
                reply(child.stdin,{'seq':0,'ok':True});steps=1;continue
            state,stored=intent.read()
            if (stored!=receipt or state is None or state['plan']!=plan or set(event)!={'seq','created_id'}
                    or type(event['seq']) is not int or event['seq']!=steps+1 or event['seq'] not in (1,2)):
                raise ValueError('cb_native_bookmark/step')
            if event['seq']==1:
                if state['phase']!='create_pending':raise ValueError('cb_native_bookmark/intent')
                target=observe(baseline,read(),body)
                if not target or target['id']!=event['created_id']:raise ValueError('cb_native_bookmark/target')
                receipt=intent.advance(receipt,'created',target=target)
                if observe(baseline,read(),body,target=target)!=target:raise ValueError('cb_native_bookmark/target')
                receipt=intent.advance(receipt,'delete_pending')
            else:
                if state['phase']!='delete_pending' or state['target']!=target or event['created_id']!=target['id']:
                    raise ValueError('cb_native_bookmark/target')
                observe(baseline,read(),body,deleted=True,target=target)
            steps=event['seq'];reply(child.stdin,dict(seq=steps,ok=True,created_id=event['created_id']))
        status=child.wait(timeout=15)
        expected=dict(result='PASS' if armed else 'DRY_RUN',profile_removed=True,installed_bytes_match=True,stage=None,
                      native_controls=True,writes=2 if armed else 0,fresh_offline=armed,credentials_not_persisted=True)
        if result!=expected:
            stage=result.get('stage') if isinstance(result,dict) else None
            if (not isinstance(stage,dict) or set(stage)!={'result','phase','failure_line'}
                    or stage['result'] not in ('PASS','UNVERIFIED','DRY_RUN')
                    or stage['phase'] not in ('decode','prepare','create','delete','reopen')
                    or type(stage['failure_line']) is not int or not 0<=stage['failure_line']<=1000):
                stage=None
            raise TrialFailure(stage)
        if status or steps!=(2 if armed else 1):raise ValueError('cb_native_bookmark/child')
        if not authority():raise ValueError('cb_native_bookmark/result')
        if armed:
            observe(baseline,read(),body,deleted=True,target=target)
            receipt=intent.advance(receipt,'verified');intent.finish(receipt)
            if intent.read()!=(None,None):raise ValueError('cb_native_bookmark/intent')
        elif read()!=baseline:raise ValueError('cb_native_bookmark/changed')
        return dict(result='PASS' if armed else 'DRY_RUN',writes=2 if armed else 0,
                    independent_readbacks=2 if armed else 0,profile_removed=True,fresh_offline=armed)
    finally:
        if child is not None:stop(child)


def run(saved,session,native_store,grant,journal,intent,command,*,apply=False,
        uploader=reading_upload,upload_factory=UploadProbe,observer_factory=Observer,source_factory=CbReadingProbe,ui_runner=run_ui):
    report=dict(result='UNVERIFIED',phase='preflight',native_writes_allocated=0,authentication_posts=0,
                fixture_only=True,existing_book_writes=0,private_values_in_report=False)
    current={'saved':saved,'sample':None,'observer':None,'ui':None}
    def same_grant(value):return native_store.load(current['saved']['vid'])==value
    def source(target):
        web=source_factory();web.vid=current['saved']['vid'];web.allowed={target}
        try:
            for key,value in current['saved']['cookies'].items():web.set_cookie(key,value)
            web.verify_account();sample=web.inspect(target);web.verify_account()
            if (sample.get('book_id')!=target or sample.get('source_format')!='web_xhtml' or TEXT not in sample.get('source','')
                    or set(web.last_checks)!={'catalog_unchanged','versions_unchanged','position_unchanged'}
                    or not all(value is True for value in web.last_checks.values())):return False
            current['sample']=sample
            if save_refreshed_web_session(session,current['saved'],web):
                old=current['saved'];current['saved']=session.load()
                if old['vid']!=current['saved']['vid']:raise ValueError('cb_native_bookmark/owner')
                old.clear()
            return True
        finally:web.samples.clear();web.close()
    def trial(upload,receipt,_upload_plan,target):
        owner=current['saved']['vid'];sample=current['sample']
        def authority():return bool(cb_id(target) and owned(upload,receipt,target,owner,grant,same_grant))
        if not authority():return False
        if sample is None:return True
        state,_=upload.read();observer=observer_factory(target,grant,authority,intent);current['observer']=observer
        stage='observe'
        try:
            baseline=observer.observe(grant);version=observer.version(grant)
            if version==0 or observer.version(grant)!=version:raise ValueError('cb_native_bookmark/version')
            stage='prepare';plan,body=prepare(owner,target,state['attempt'],sample,version,baseline)
            point=from_mark(sample['source'],target,sample['chapter_uid'],body)
            chapters=[dict(row) for row in sample['chapters']]
            chosen=[row for row in chapters if str(row.get('chapterUid'))==sample['chapter_uid']]
            if len(chosen)!=1 or type(chosen[0].get('chapterIdx')) is not int:raise ValueError('cb_native_bookmark/chapter')
            payload=dict(book=target,chapter=sample['chapter_uid'],chapter_idx=chosen[0]['chapterIdx'],source=sample['source'],
                chapters=chapters,cookies=current['saved']['cookies'],native=grant,owner=owner,book_version=version,
                body=body,first=point['chapter_offset'])
            read=lambda:observer.observe(grant)
            stage='dry';dry=ui_runner(command,payload,plan,body,baseline,intent,authority,read,armed=False)
            if dry['result']!='DRY_RUN' or not authority() or read()!=baseline:return False
            report['dry_run_blocked']=True
            report['native_writes_allocated']=2
            stage='native';current['ui']=ui_runner(command,payload,plan,body,baseline,intent,authority,read,armed=True)
            if current['ui']['result']!='PASS':return False
            observe(baseline,read(),body,deleted=True)
            old=sample;current['sample']=None
            if not source(target):return False
            after=current['sample']
            return bool(authority() and after['source_raw_sha256']==old['source_raw_sha256']
                and after['chapter_uid']==old['chapter_uid'] and after['chapters']==old['chapters'] and after['baseline']==old['baseline'])
        except Exception as error:
            report['validation_stage']=stage
            if isinstance(error,TrialFailure) and error.stage is not None:report['native_stage']=error.stage
            return bool(report['native_writes_allocated']==0 and intent.read()[0] is None and authority())
    try:
        if journal.read()[0] is not None or intent.read()[0] is not None:raise ValueError('cb_native_bookmark/consumed')
        upload=upload_factory(journal,same_grant)
        result=uploader(upload,journal,grant,same_grant,source,apply=apply,cleanup_gate=trial)
        report['upload']=result;report['phase']=result.get('phase','unknown')
        if result.get('result')=='READ_ONLY_PREVIEW':report['result']='READ_ONLY_PREVIEW'
        elif result.get('result')=='EPUB_IMPORT_AND_SOURCE_VERIFIED' and current['ui'] and current['ui']['result']=='PASS':
            report.update(result='CB_NATIVE_BOOKMARK_VERIFIED',native_writes=2,independent_readbacks=2,
                          fresh_offline=True,fixture_removed=True,original_records_restored=True,no_replay=True)
    except Exception:report['result']='UNVERIFIED'
    finally:
        current['sample']=None
        if current['saved'] is not saved and saved:saved.clear()
        if current['saved']:current['saved'].clear()
    return report


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--apply',action='store_true');parser.add_argument('--runner',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    if args.apply and not args.saved_session or args.saved_session and not args.runner or args.runner and not args.saved_session:
        parser.error('saved session and runner required')
    if not args.saved_session:print(json.dumps(dict(result='OFFLINE_ONLY',native_writes_allocated=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=None
    try:
        session=SessionStore();saved=session.load();native=NativeSessionStore();grant=native.load(saved['vid'])
        report=run(saved,session,native,grant,*stores(),args.runner,apply=args.apply)
    except Exception:report=dict(result='UNVERIFIED',phase='setup',native_writes_allocated=0)
    finally:
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(report,ensure_ascii=False));return int(report['result'] not in ('READ_ONLY_PREVIEW','CB_NATIVE_BOOKMARK_VERIFIED'))


if __name__=='__main__':raise SystemExit(main())
