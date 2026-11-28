#!/usr/bin/env python3
"""Verify one private thought lifecycle on a newly uploaded synthetic CB book.

Offline by default. Apply creates one fixture-only highlight, creates/edits/
deletes one private thought, then removes that new highlight and the book.
Every write has a durable one-shot phase and independent complete readback.
Unknown effects stop without retry or automatic fixture cleanup.
"""
import argparse
import json
from pathlib import Path
import resource
import secrets
import tempfile

from annotation_experiment_model import digest,note_text
from cb_fixture_highlight_trial import Intent as SeedIntent,prepare as prepare_highlight
from cb_fixture_thought_trial import ThoughtIntent,execute
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

UPLOAD_SERVICE='org.codex.weread.cb-fixture-thought-upload-v1'
SEED_SERVICE='org.codex.weread.cb-fixture-thought-seed-v1'


def stores():
    def backend(service):return MacKeychain(service=service,account=ACCOUNT)
    def lock(name):
        path=Path(tempfile.gettempdir())/('codex-cb-fixture-thought-'+name+'-'+ACCOUNT+'.lock')
        return lambda:project_lock(path)
    return (Journal(backend=backend(UPLOAD_SERVICE),lock=lock('upload')),
            SeedIntent(backend=backend(SEED_SERVICE),lock=lock('seed')),ThoughtIntent())


class ScopedThoughtNative(ScopedNative):
    def __init__(self,book,grant,authority,seed_intent,thought_intent,*,opener=None):
        super().__init__(book,grant,authority,seed_intent,opener=opener,max_gets=80)
        self.thought_intent=thought_intent;self.thought_posts=0;self.thought_pending=None

    def request(self,stage,url,body=None,credentials=None,timeout=15):
        if stage not in ('thought_create_pending','thought_edit_pending','thought_delete_pending'):
            return super().request(stage,url,body,credentials,timeout)
        phase=stage.removeprefix('thought_');state,receipt=self.thought_intent.read()
        if (not self.authority() or digest(credentials)!=self.grant_hash or self.thought_pending!=(phase,receipt)
                or state is None or not self.thought_intent.owns(receipt,phase) or state['plan']['book_sha256']!=digest(self.book)
                or state['plan']['owner_sha256']!=digest(credentials['vid'])
                or self.thought_posts!=({'create_pending':0,'edit_pending':1,'delete_pending':2}[phase])):
            raise ValueError('cb_thought/write_scope')
        if phase=='create_pending':
            if (url!=BASE+'/review/add' or not isinstance(body,dict) or body.get('bookId')!=self.book
                    or body.get('isPrivate')!=1 or digest(body)!=state['plan']['request_sha256']):raise ValueError('cb_thought/write_scope')
        elif phase=='edit_pending':
            if url!=BASE+'/review/useredit' or body!=dict(reviewId=state['created_id'],content=note_text(state['plan']['nonce'],True)):
                raise ValueError('cb_thought/write_scope')
        elif url!=BASE+'/review/delete' or body!=dict(reviewId=state['created_id']):raise ValueError('cb_thought/write_scope')
        self.thought_posts+=1
        value=NativeProbe.request(self,stage,url,body,credentials,timeout)
        if not self.authority():raise ValueError('cb_thought/ownership')
        return value

    def send_thought(self,phase,body,receipt,grant):
        if self.thought_pending is not None:raise ValueError('cb_thought/write_scope')
        self.thought_pending=(phase,receipt)
        paths={'create_pending':'/review/add','edit_pending':'/review/useredit','delete_pending':'/review/delete'}
        try:return self.request('thought_'+phase,BASE+paths[phase],body,grant)
        finally:self.thought_pending=None


def run(saved,session,native_store,grant,journal,seed_intent,thought_intent,*,apply=False,
        uploader=upload_run,upload_factory=UploadProbe,native_factory=ScopedThoughtNative,source_factory=CbReadingProbe):
    report=dict(result='UNVERIFIED',phase='preflight',seed_posts=0,thought_posts=0,authentication_posts=0,
                fixture_only=True,existing_book_writes=0,private_values_in_report=False)
    current={'saved':saved,'sample':None,'native':None,'trial':None}
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
                if old['vid']!=current['saved']['vid']:raise ValueError('cb_thought/owner')
                old.clear()
            return True
        finally:web.samples.clear();web.close()
    def trial(upload,receipt,_plan,target):
        owner=current['saved']['vid'];sample=current['sample']
        def authority():return bool(cb_id(target) and owned(upload,receipt,target,owner,grant,same_grant))
        if not authority():return False
        if sample is None:return True
        state,_=upload.read();native=native_factory(target,grant,authority,seed_intent,thought_intent);current['native']=native
        try:
            before=native.observe(grant);version=native.version(grant)
            if native.version(grant)!=version:raise ValueError('cb_thought/version')
            _plan,body=prepare_highlight(owner,target,state['attempt'],sample,version,before);native.body=body
            current['trial']=execute(owner,target,state['attempt'],sample,version,before,seed_intent,thought_intent,authority,
                lambda:native.observe(grant),lambda phase,value,permit:native.send(phase,value,permit,grant),
                lambda phase,value,permit:native.send_thought(phase,value,permit,grant),nonce=secrets.token_hex(16))
            if native.posts!=2 or native.thought_posts!=3 or native.observe(grant)!=before:return False
            old=sample;current['sample']=None
            if not source(target):return False
            after=current['sample']
            return bool(authority() and after['source_raw_sha256']==old['source_raw_sha256']
                and after['chapter_uid']==old['chapter_uid'] and after['chapters']==old['chapters'] and after['baseline']==old['baseline'])
        except Exception:
            return bool(native.posts==0 and native.thought_posts==0 and seed_intent.read()[0] is None
                        and thought_intent.read()[0] is None and authority())
        finally:
            report['seed_posts']=native.posts;report['thought_posts']=native.thought_posts
    try:
        if any(store.read()[0] is not None for store in (journal,seed_intent,thought_intent)):raise ValueError('cb_thought/consumed')
        upload=upload_factory(journal,same_grant)
        result=uploader(upload,journal,grant,same_grant,source,apply=apply,cleanup_gate=trial)
        report['upload']=result;report['phase']=result.get('phase','unknown')
        if result.get('result')=='READ_ONLY_PREVIEW':report['result']='READ_ONLY_PREVIEW'
        elif result.get('result')=='EPUB_IMPORT_AND_SOURCE_VERIFIED' and current['trial'] and current['trial']['result']=='PASS':
            report.update(result='CB_FIXTURE_THOUGHT_VERIFIED',fixture_removed=True,original_records_restored=True,no_replay=True)
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
    if not args.saved_session:print(json.dumps(dict(result='OFFLINE_ONLY',seed_posts=0,thought_posts=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=None
    try:
        session=SessionStore();saved=session.load();native=NativeSessionStore();grant=native.load(saved['vid'])
        report=run(saved,session,native,grant,*stores(),apply=args.apply)
    except Exception:report=dict(result='UNVERIFIED',phase='setup',seed_posts=0,thought_posts=0)
    finally:
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(report,ensure_ascii=False));return int(report['result'] not in ('READ_ONLY_PREVIEW','CB_FIXTURE_THOUGHT_VERIFIED'))


if __name__=='__main__':raise SystemExit(main())
