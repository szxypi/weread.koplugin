#!/usr/bin/env python3
"""One fresh CB fixture, native save/delete and independent host readbacks.

Offline by default. Apply creates one self-authored fixture, first blocks the
native write as a dry run, then reserves two one-shot native writes. Unknown
effects retain the exact fixture and intent; neither process may replay them.
"""
import argparse
import json
from pathlib import Path
import resource
import secrets
import subprocess
import tempfile
import time

from cb_fixture_highlight_trial import Intent as BaseIntent, prepare
from highlight_trial_model import observe
from my_mark_span import project as span_project
from native_trial_pipe import Frames, reply, stop, write_initial
from secure_native_session import NativeSessionStore, project_lock
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from synthetic_epub_trial import Journal
from synthetic_upload_epub import TEXT
from verify_cb_fixture_highlight_trial import ScopedNative
from verify_cb_fixture_position_trial import owned
from verify_cb_progress import cb_id
from verify_cb_reading import CbReadingError, CbReadingProbe
from verify_cb_metadata import CbMetadataError
from verify_personal_upload_trial import Probe as UploadProbe
from verify_synthetic_epub_upload import run as upload_run
from verify_translation_preflight import save_refreshed_web_session

UPLOAD_SERVICE='org.codex.weread.cb-native-highlight-upload-v1'
INTENT_SERVICE='org.codex.weread.cb-native-highlight-intent-v1'


def stores():
    def backend(service): return MacKeychain(service=service, account=ACCOUNT)
    def lock(name):
        path=Path(tempfile.gettempdir())/('codex-cb-native-highlight-'+name+'-'+ACCOUNT+'.lock')
        return lambda:project_lock(path)
    return Journal(backend=backend(UPLOAD_SERVICE),lock=lock('upload')),BaseIntent(backend=backend(INTENT_SERVICE),lock=lock('intent'))


class Observer(ScopedNative):
    def __init__(self,*args,**kwargs):
        super().__init__(*args,max_gets=80,**kwargs)

    def request(self,stage,url,body=None,credentials=None,timeout=15):
        if body is not None:raise ValueError('cb_native_highlight/host_write_forbidden')
        return super().request(stage,url,body,credentials,timeout)


def run_ui(command,payload,plan,body,baseline,intent,authority,read,*,armed=False):
    if type(armed) is not bool or not command or any(not isinstance(v,str) or not v for v in command):
        raise ValueError('cb_native_highlight/command')
    if intent.read()!=(None,None) or not authority() or read()!=baseline:raise ValueError('cb_native_highlight/preflight')
    value=dict(payload,armed=armed,token=secrets.token_hex(16));receipt=intent.reserve(plan) if armed else None
    child=None;steps=0;target=None
    try:
        child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
        write_initial(child.stdin,value);frames=Frames(child.stdout,value['token'],timeout=600)
        while True:
            kind,event=frames.next()
            if kind=='RESULT':
                result=event;break
            if not authority():raise ValueError('cb_native_highlight/ownership')
            if not armed:
                if steps or event!={'seq':0,'preview':body} or read()!=baseline:raise ValueError('cb_native_highlight/dry')
                reply(child.stdin,{'seq':0,'ok':True});steps=1;continue
            state,stored=intent.read()
            if (stored!=receipt or state is None or state['plan']!=plan or set(event)!={'seq','created_id'}
                    or type(event['seq']) is not int or event['seq']!=steps+1 or event['seq'] not in (1,2)):
                raise ValueError('cb_native_highlight/step')
            if event['seq']==1:
                if state['phase']!='create_pending':raise ValueError('cb_native_highlight/intent')
                target=observe(baseline,read(),body)
                if not target or target['id']!=event['created_id']:raise ValueError('cb_native_highlight/target')
                receipt=intent.advance(receipt,'created',target=target)
                if observe(baseline,read(),body,target=target)!=target:raise ValueError('cb_native_highlight/target')
                receipt=intent.advance(receipt,'delete_pending')
            else:
                if state['phase']!='delete_pending' or state['target']!=target or event['created_id']!=target['id']:
                    raise ValueError('cb_native_highlight/target')
                observe(baseline,read(),body,deleted=True,target=target)
            steps=event['seq'];reply(child.stdin,dict(seq=steps,ok=True,created_id=event['created_id']))
        if child.wait(timeout=15) or steps!=(2 if armed else 1):raise ValueError('cb_native_highlight/child')
        expected=dict(result='PASS' if armed else 'DRY_RUN',profile_removed=True,installed_bytes_match=True,stage=None,
                      native_controls=True,writes=2 if armed else 0,fresh_offline=armed,credentials_not_persisted=True)
        if result!=expected or not authority():raise ValueError('cb_native_highlight/result')
        if armed:
            observe(baseline,read(),body,deleted=True,target=target)
            receipt=intent.advance(receipt,'verified');intent.finish(receipt)
            if intent.read()!=(None,None):raise ValueError('cb_native_highlight/intent')
        elif read()!=baseline:raise ValueError('cb_native_highlight/changed')
        return dict(result='PASS' if armed else 'DRY_RUN',writes=2 if armed else 0,
                    independent_readbacks=2 if armed else 0,profile_removed=True,fresh_offline=armed)
    finally:
        if child is not None:stop(child)


def run(saved,session,native_store,grant,journal,intent,command,*,apply=False,
        uploader=upload_run,upload_factory=UploadProbe,observer_factory=Observer,source_factory=CbReadingProbe,ui_runner=run_ui,
        prepare_fn=prepare,native_writes=2,result_label='CB_NATIVE_HIGHLIGHT_VERIFIED',final_check=None,source_sleep=time.sleep):
    report=dict(result='UNVERIFIED',phase='preflight',native_writes_allocated=0,authentication_posts=0,
                fixture_only=True,existing_book_writes=0,private_values_in_report=False)
    current={'saved':saved,'sample':None,'observer':None,'ui':None}
    def same_grant(value):return native_store.load(current['saved']['vid'])==value
    def source(target):
        current['sample']=None
        for attempt in range(3):
            web=source_factory();web.vid=current['saved']['vid'];web.allowed={target}
            try:
                for key,value in current['saved']['cookies'].items():web.set_cookie(key,value)
                web.verify_account();sample=web.inspect(target);web.verify_account()
                if (sample.get('book_id')!=target or sample.get('source_format')!='web_xhtml' or TEXT not in sample.get('source','')
                        or set(web.last_checks)!={'catalog_unchanged','versions_unchanged','position_unchanged'}
                        or not all(value is True for value in web.last_checks.values())):
                    report['source_failure']='invalid_sample';return False
                if save_refreshed_web_session(session,current['saved'],web):
                    old=current['saved'];current['saved']=session.load()
                    if old['vid']!=current['saved']['vid']:raise ValueError('cb_native_highlight/owner')
                    old.clear()
                report.pop('source_failure',None);current['sample']=sample
                return True
            except (CbReadingError,CbMetadataError) as error:
                known={'cb_catalog_empty','cb_catalog_invalid','cb_catalog_identity','cb_resume_chapter_missing',
                       'cb_reader_chapter_mismatch','cb_txt_marker_invalid','cb_source_invalid','cb_read_baseline_changed',
                       'cb_source_anchor_unavailable','cb_content_scope','cb_read_scope','cb_read_repeated'}
                report['source_failure']=str(error) if str(error) in known else 'other'
                if str(error) not in ('cb_catalog_empty','cb_catalog_invalid') or attempt==2:raise
            except Exception:
                report['source_failure']='other';raise
            finally:web.samples.clear();web.close()
            source_sleep(2*(attempt+1))
        return False
    def trial(upload,receipt,_upload_plan,target):
        owner=current['saved']['vid'];sample=current['sample']
        def authority():return bool(cb_id(target) and owned(upload,receipt,target,owner,grant,same_grant))
        if not authority():return False
        if sample is None:return True
        state,_=upload.read();observer=observer_factory(target,grant,authority,intent);current['observer']=observer
        stage='observe'
        try:
            baseline=observer.observe(grant);version=observer.version(grant)
            if version==0 or observer.version(grant)!=version:raise ValueError('cb_native_highlight/version')
            stage='prepare'
            plan,body=prepare_fn(owner,target,state['attempt'],sample,version,baseline)
            row={'type':1,'chapterUid':body['chapterUid'],'range':body['range'],'markText':body['markText']}
            span=span_project(sample['source'],target,sample['chapter_uid'],row)
            chapters=[dict(row) for row in sample['chapters']]
            chosen=[row for row in chapters if str(row.get('chapterUid'))==sample['chapter_uid']]
            if len(chosen)!=1 or type(chosen[0].get('chapterIdx')) is not int:raise ValueError('cb_native_highlight/chapter')
            payload=dict(book=target,chapter=sample['chapter_uid'],chapter_idx=chosen[0]['chapterIdx'],source=sample['source'],
                chapters=chapters,cookies=current['saved']['cookies'],native=grant,owner=owner,book_version=version,
                body=body,first=span['first'],last=span['last'])
            read=lambda:observer.observe(grant)
            stage='dry'
            dry=ui_runner(command,payload,plan,body,baseline,intent,authority,read,armed=False)
            if dry['result']!='DRY_RUN' or not authority() or read()!=baseline:return False
            report['dry_run_blocked']=True
            report['native_writes_allocated']=native_writes
            stage='native'
            current['ui']=ui_runner(command,payload,plan,body,baseline,intent,authority,read,armed=True)
            after_marks=read()
            if current['ui']['result']!='PASS' or not (final_check(baseline,after_marks,body) if final_check else after_marks==baseline):return False
            old=sample;current['sample']=None
            if not source(target):return False
            after=current['sample']
            return bool(authority() and after['source_raw_sha256']==old['source_raw_sha256']
                and after['chapter_uid']==old['chapter_uid'] and after['chapters']==old['chapters'] and after['baseline']==old['baseline'])
        except Exception as error:
            report['validation_stage']=stage
            detail=getattr(error,'stage',None)
            if (isinstance(detail,dict) and set(detail)=={'result','phase','failure_line'}
                    and detail['result'] in ('PASS','UNVERIFIED','DRY_RUN')
                    and detail['phase'] in ('decode','prepare','create','style0','style2','color0','color3','delete','reopen')
                    and type(detail['failure_line']) is int and 0<=detail['failure_line']<=1000):report['native_stage']=detail
            return bool(report['native_writes_allocated']==0 and intent.read()[0] is None and authority())
    try:
        if journal.read()[0] is not None or intent.read()[0] is not None:raise ValueError('cb_native_highlight/consumed')
        upload=upload_factory(journal,same_grant)
        result=uploader(upload,journal,grant,same_grant,source,apply=apply,cleanup_gate=trial)
        report['upload']=result;report['phase']=result.get('phase','unknown')
        if result.get('result')=='READ_ONLY_PREVIEW':report['result']='READ_ONLY_PREVIEW'
        elif result.get('result')=='EPUB_IMPORT_AND_SOURCE_VERIFIED' and current['ui'] and current['ui']['result']=='PASS':
            report.update(result=result_label,native_writes=native_writes,independent_readbacks=native_writes,
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
    print(json.dumps(report,ensure_ascii=False));return int(report['result'] not in ('READ_ONLY_PREVIEW','CB_NATIVE_HIGHLIGHT_VERIFIED'))


if __name__=='__main__':raise SystemExit(main())
