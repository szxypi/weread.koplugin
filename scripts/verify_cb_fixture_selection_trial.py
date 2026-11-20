#!/usr/bin/env python3
"""Test a new selection on one fresh self-authored CB fixture.

Offline by default. Explicit apply reserves three thought writes and one
optional exact associated-mark cleanup. Uncertain effects retain the fixture
and durable reservation; no write is automatically retried.
"""
import argparse
import json
from pathlib import Path
import resource
import secrets
import tempfile

from annotation_experiment_model import digest,note_text
from cb_fixture_selection_trial import Intent,execute,prepare
from secure_native_session import NativeSessionStore,project_lock
from secure_weread_session import ACCOUNT,MacKeychain,SessionStore
from synthetic_epub_trial import Journal
from synthetic_upload_epub import TEXT
from verify_cb_fixture_highlight_trial import ScopedNative
from verify_cb_fixture_position_trial import owned
from verify_cb_progress import cb_id
from verify_cb_reading import CbReadingProbe
from verify_eink_login import BASE,NativeProbe
from verify_personal_upload_trial import Probe as UploadProbe
from verify_synthetic_epub_upload import run as upload_run
from verify_translation_preflight import save_refreshed_web_session

UPLOAD_SERVICE='org.codex.weread.cb-fixture-selection-upload-v1'


def stores():
    def backend(service):return MacKeychain(service=service,account=ACCOUNT)
    def lock(name):
        path=Path(tempfile.gettempdir())/('codex-cb-fixture-selection-'+name+'-'+ACCOUNT+'.lock')
        return lambda:project_lock(path)
    return Journal(backend=backend(UPLOAD_SERVICE),lock=lock('upload')),Intent()


class ScopedSelectionNative(ScopedNative):
    def __init__(self,book,grant,authority,intent,*,opener=None):
        super().__init__(book,grant,authority,intent,opener=opener,max_gets=80)
        self.thought_posts=0;self.cleanup_posts=0;self.write_pending=None

    def request(self,stage,url,body=None,credentials=None,timeout=15):
        if stage not in ('selection_thought','selection_cleanup'):
            return super().request(stage,url,body,credentials,timeout)
        state,receipt=self.intent.read()
        if (not self.authority() or digest(credentials)!=self.grant_hash or self.write_pending!=(stage,receipt)
                or state is None or state['phase']!='pending' or state['plan']['book_sha256']!=digest(self.book)
                or state['plan']['owner_sha256']!=digest(credentials['vid'])):raise ValueError('cb_selection/scope')
        if stage=='selection_thought':
            step=self.thought_posts+1
            if not 1<=step<=3 or state['native_steps']!=step-1 or state['cleanup_pending'] or state['cleanup_verified']:
                raise ValueError('cb_selection/step')
            if step==1:
                if (url!=BASE+'/review/add' or not isinstance(body,dict) or body.get('bookId')!=self.book
                        or body.get('isPrivate')!=1 or digest(body)!=state['plan']['request_sha256']):raise ValueError('cb_selection/body')
            elif step==2:
                if url!=BASE+'/review/useredit' or body!=dict(reviewId=state['created_id'],content=note_text(state['plan']['nonce'],True)):
                    raise ValueError('cb_selection/body')
            elif url!=BASE+'/review/delete' or body!=dict(reviewId=state['created_id']):raise ValueError('cb_selection/body')
            self.thought_posts+=1
        else:
            if (url!=BASE+'/book/removeBookmark' or state['native_steps']!=3 or not state['cleanup_pending']
                    or state['cleanup_verified'] or self.cleanup_posts or state['mark'] is None
                    or body!={'bookmarkIds':[state['mark']['id']]}):raise ValueError('cb_selection/cleanup')
            self.cleanup_posts+=1
        result=NativeProbe.request(self,stage,url,body,credentials,timeout)
        if not self.authority():raise ValueError('cb_selection/ownership')
        return result

    def send_thought(self,step,body,receipt,grant):
        if self.write_pending is not None or step!=self.thought_posts+1:raise ValueError('cb_selection/step')
        paths={1:'/review/add',2:'/review/useredit',3:'/review/delete'}
        self.write_pending=('selection_thought',receipt)
        try:return self.request('selection_thought',BASE+paths[step],body,grant)
        finally:self.write_pending=None

    def send_cleanup(self,body,receipt,grant):
        if self.write_pending is not None:raise ValueError('cb_selection/cleanup')
        self.write_pending=('selection_cleanup',receipt)
        try:return self.request('selection_cleanup',BASE+'/book/removeBookmark',body,grant)
        finally:self.write_pending=None


def run(saved,session,native_store,grant,journal,intent,*,apply=False,
        uploader=upload_run,upload_factory=UploadProbe,native_factory=ScopedSelectionNative,source_factory=CbReadingProbe):
    report=dict(result='UNVERIFIED',phase='preflight',thought_posts=0,cleanup_posts=0,authentication_posts=0,
                fixture_only=True,existing_book_writes=0,private_values_in_report=False)
    current={'saved':saved,'sample':None,'trial':None}
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
                if old['vid']!=current['saved']['vid']:raise ValueError('cb_selection/owner')
                old.clear()
            return True
        finally:web.samples.clear();web.close()
    def trial(upload,receipt,_plan,target):
        owner=current['saved']['vid'];sample=current['sample']
        def authority():return bool(cb_id(target) and owned(upload,receipt,target,owner,grant,same_grant))
        if not authority():return False
        if sample is None:return True
        state,_=upload.read();native=native_factory(target,grant,authority,intent)
        try:
            before=native.observe(grant);version=native.version(grant)
            if native.version(grant)!=version:raise ValueError('cb_selection/version')
            plan,context,body=prepare(owner,target,state['attempt'],sample,version,before,secrets.token_hex(16))
            current['trial']=execute(plan,context,body,before,intent,authority,lambda:native.observe(grant),
                lambda step,value,permit:native.send_thought(step,value,permit,grant),
                lambda value,permit:native.send_cleanup(value,permit,grant))
            if native.thought_posts!=3 or native.cleanup_posts!=current['trial']['cleanup_writes']:return False
            old=sample;current['sample']=None
            if not source(target):return False
            after=current['sample']
            return bool(authority() and after['source_raw_sha256']==old['source_raw_sha256']
                and after['chapter_uid']==old['chapter_uid'] and after['chapters']==old['chapters'] and after['baseline']==old['baseline'])
        except Exception:
            return bool(native.thought_posts==0 and native.cleanup_posts==0 and intent.read()[0] is None and authority())
        finally:report['thought_posts']=native.thought_posts;report['cleanup_posts']=native.cleanup_posts
    try:
        if journal.read()[0] is not None or intent.read()[0] is not None:raise ValueError('cb_selection/consumed')
        upload=upload_factory(journal,same_grant)
        result=uploader(upload,journal,grant,same_grant,source,apply=apply,cleanup_gate=trial)
        report['upload']=result;report['phase']=result.get('phase','unknown')
        if result.get('result')=='READ_ONLY_PREVIEW':report['result']='READ_ONLY_PREVIEW'
        elif result.get('result')=='EPUB_IMPORT_AND_SOURCE_VERIFIED' and current['trial'] and current['trial']['result']=='PASS':
            report.update(result='CB_FIXTURE_SELECTION_VERIFIED',fixture_removed=True,original_records_restored=True,no_replay=True,
                          associated_highlight_observed=current['trial']['associated_highlight_observed'],
                          derived_chapter_metadata_changed=current['trial']['derived_chapter_metadata_changed'])
    except Exception:report['result']='UNVERIFIED'
    finally:
        current['sample']=None
        if current['saved'] is not saved and saved:saved.clear()
        if current['saved']:current['saved'].clear()
    return report


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');parser.add_argument('--apply',action='store_true')
    args=parser.parse_args(argv)
    if args.apply and not args.saved_session:parser.error('apply requires saved session')
    if not args.saved_session:print(json.dumps(dict(result='OFFLINE_ONLY',thought_posts=0,cleanup_posts=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=None
    try:
        session=SessionStore();saved=session.load();native=NativeSessionStore();grant=native.load(saved['vid'])
        report=run(saved,session,native,grant,*stores(),apply=args.apply)
    except Exception:report=dict(result='UNVERIFIED',phase='setup',thought_posts=0,cleanup_posts=0)
    finally:
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(report,ensure_ascii=False));return int(report['result'] not in ('READ_ONLY_PREVIEW','CB_FIXTURE_SELECTION_VERIFIED'))


if __name__=='__main__':raise SystemExit(main())
