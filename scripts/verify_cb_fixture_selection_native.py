#!/usr/bin/env python3
"""Native selection trial on one fresh, self-authored imported book.

Offline by default. Apply blocks the first native write in a dry run, then
reserves three native writes and optional exact-mark cleanup. Uncertain
outcomes retain the fixture and one-shot journal; nothing is resent.
"""
import argparse
import json
from pathlib import Path
import resource
import secrets
import tempfile

from annotation_experiment_model import note_text
from cb_fixture_selection_native_bridge import NativeSelectionBridge
from cb_fixture_selection_trial import Intent,execute,prepare
from my_mark_span import project as span_project
from secure_native_session import NativeSessionStore,project_lock
from secure_weread_session import ACCOUNT,MacKeychain,SessionStore
from synthetic_epub_trial import Journal
from synthetic_upload_epub import TEXT
from verify_cb_fixture_position_trial import owned
from verify_cb_fixture_selection_trial import ScopedSelectionNative
from verify_cb_progress import cb_id
from verify_cb_reading import CbReadingProbe
from verify_personal_upload_trial import Probe as UploadProbe
from verify_synthetic_epub_upload import run as upload_run
from verify_translation_preflight import save_refreshed_web_session

UPLOAD_SERVICE='org.codex.weread.cb-native-selection-upload-v1'
INTENT_SERVICE='org.codex.weread.cb-native-selection-intent-v1'


def stores():
    def backend(service):return MacKeychain(service=service,account=ACCOUNT)
    def lock(name):
        path=Path(tempfile.gettempdir())/('codex-cb-native-selection-'+name+'-'+ACCOUNT+'.lock')
        return lambda:project_lock(path)
    return Journal(backend=backend(UPLOAD_SERVICE),lock=lock('upload')),Intent(backend=backend(INTENT_SERVICE),lock=lock('intent'))


def run(saved,session,native_store,grant,journal,intent,command,*,apply=False,uploader=upload_run,
        upload_factory=UploadProbe,native_factory=ScopedSelectionNative,source_factory=CbReadingProbe,bridge_factory=NativeSelectionBridge):
    report=dict(result='UNVERIFIED',phase='preflight',native_thought_steps=0,cleanup_posts=0,authentication_posts=0,
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
                if old['vid']!=current['saved']['vid']:raise ValueError('cb_native_selection/owner')
                old.clear()
            return True
        finally:web.samples.clear();web.close()
    def trial(upload,receipt,_plan,target):
        owner=current['saved']['vid'];sample=current['sample']
        def authority():return bool(cb_id(target) and owned(upload,receipt,target,owner,grant,same_grant))
        if not authority():return False
        if sample is None:return True
        state,_=upload.read();native=native_factory(target,grant,authority,intent);bridge=None
        try:
            before=native.observe(grant);version=native.version(grant)
            if not version or native.version(grant)!=version:raise ValueError('cb_native_selection/version')
            nonce=secrets.token_hex(16)
            plan,context,body=prepare(owner,target,state['attempt'],sample,version,before,nonce)
            span=span_project(sample['source'],target,sample['chapter_uid'],dict(type=1,chapterUid=int(context['chapterUid']),
                range=context['range'],markText=context['abstract']))
            chapters=[dict(row) for row in sample['chapters']]
            chosen=[row for row in chapters if str(row.get('chapterUid'))==sample['chapter_uid']]
            if len(chosen)!=1 or type(chosen[0].get('chapterIdx')) is not int:raise ValueError('cb_native_selection/chapter')
            payload=dict(book=target,chapter=sample['chapter_uid'],chapter_idx=chosen[0]['chapterIdx'],source=sample['source'],
                chapters=chapters,cookies=current['saved']['cookies'],native=grant,owner=owner,book_version=version,
                body=body,edited_text=note_text(nonce,True),first=span['first'],last=span['last'])
            read=lambda:native.observe(grant)
            bridge=bridge_factory(command,payload,plan,before,intent,authority,read)
            current['trial']=execute(plan,context,body,before,intent,authority,read,bridge.send,
                lambda value,permit:native.send_cleanup(value,permit,grant),before_finish=bridge.finish)
            if (bridge.steps!=3 or not bridge.dry_verified or not bridge.completed
                    or native.cleanup_posts!=current['trial']['cleanup_writes']):return False
            old=sample;current['sample']=None
            if not source(target):return False
            after=current['sample']
            return bool(authority() and after['source_raw_sha256']==old['source_raw_sha256']
                and after['chapter_uid']==old['chapter_uid'] and after['chapters']==old['chapters'] and after['baseline']==old['baseline'])
        except Exception:
            return bool((bridge is None or bridge.steps==0) and native.cleanup_posts==0 and intent.read()[0] is None and authority())
        finally:
            report['cleanup_posts']=native.cleanup_posts
            if bridge is not None:
                report['native_thought_steps']=bridge.steps;report['dry_run_blocked']=bridge.dry_verified
                report['native_ui_completed']=bridge.completed;bridge.close()
    try:
        if journal.read()[0] is not None or intent.read()[0] is not None:raise ValueError('cb_native_selection/consumed')
        upload=upload_factory(journal,same_grant)
        result=uploader(upload,journal,grant,same_grant,source,apply=apply,cleanup_gate=trial)
        report['upload']=result;report['phase']=result.get('phase','unknown')
        if result.get('result')=='READ_ONLY_PREVIEW':report['result']='READ_ONLY_PREVIEW'
        elif result.get('result')=='EPUB_IMPORT_AND_SOURCE_VERIFIED' and current['trial'] and current['trial']['result']=='PASS':
            report.update(result='CB_NATIVE_SELECTION_VERIFIED',fixture_removed=True,original_records_restored=True,no_replay=True,
                associated_highlight_observed=current['trial']['associated_highlight_observed'],
                derived_chapter_metadata_changed=current['trial']['derived_chapter_metadata_changed'],fresh_offline=True)
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
    if not args.saved_session:print(json.dumps(dict(result='OFFLINE_ONLY',native_thought_steps=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=None
    try:
        session=SessionStore();saved=session.load();native=NativeSessionStore();grant=native.load(saved['vid'])
        report=run(saved,session,native,grant,*stores(),args.runner,apply=args.apply)
    except Exception:report=dict(result='UNVERIFIED',phase='setup',native_thought_steps=0)
    finally:
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(report,ensure_ascii=False));return int(report['result'] not in ('READ_ONLY_PREVIEW','CB_NATIVE_SELECTION_VERIFIED'))


if __name__=='__main__':raise SystemExit(main())
