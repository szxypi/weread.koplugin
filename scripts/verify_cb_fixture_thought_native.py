#!/usr/bin/env python3
"""One self-authored CB fixture: host-owned seed and native thought lifecycle.

Default is offline. Apply uses independent durable journals, a blocked native
preflight, one native create/edit/delete and readback after each action. An
unknown outcome retains the fixture and prevents replay or cleanup.
"""
import argparse
import json
from pathlib import Path
import resource
import secrets
import tempfile

from cb_fixture_highlight_trial import Intent as SeedIntent, prepare
from cb_fixture_thought_native_bridge import NativeThoughtBridge
from cb_fixture_thought_trial import ThoughtIntent, execute
from secure_native_session import NativeSessionStore, project_lock
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from synthetic_epub_trial import Journal
from synthetic_upload_epub import TEXT
from verify_cb_fixture_highlight_trial import ScopedNative
from verify_cb_fixture_position_trial import owned
from verify_cb_progress import cb_id
from verify_cb_reading import CbReadingProbe
from verify_personal_upload_trial import Probe as UploadProbe
from verify_synthetic_epub_upload import run as upload_run
from verify_translation_preflight import save_refreshed_web_session

UPLOAD_SERVICE='org.codex.weread.cb-native-thought-upload-v1'
SEED_SERVICE='org.codex.weread.cb-native-thought-seed-v1'
THOUGHT_SERVICE='org.codex.weread.cb-native-thought-intent-v1'


def stores():
    def backend(service):return MacKeychain(service=service,account=ACCOUNT)
    def lock(name):
        path=Path(tempfile.gettempdir())/('codex-cb-native-thought-'+name+'-'+ACCOUNT+'.lock')
        return lambda:project_lock(path)
    return (Journal(backend=backend(UPLOAD_SERVICE),lock=lock('upload')),
            SeedIntent(backend=backend(SEED_SERVICE),lock=lock('seed')),
            ThoughtIntent(backend=backend(THOUGHT_SERVICE),lock=lock('thought')))


def run(saved,session,native_store,grant,journal,seed_intent,thought_intent,command,*,apply=False,
        uploader=upload_run,upload_factory=UploadProbe,native_factory=ScopedNative,source_factory=CbReadingProbe,
        bridge_factory=NativeThoughtBridge,mock_port=None):
    report=dict(result='UNVERIFIED',phase='preflight',seed_posts=0,native_thought_steps=0,authentication_posts=0,
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
                if old['vid']!=current['saved']['vid']:raise ValueError('cb_native_thought/owner')
                old.clear()
            return True
        finally:web.samples.clear();web.close()
    def trial(upload,receipt,_plan,target):
        owner=current['saved']['vid'];sample=current['sample']
        def authority():return bool(cb_id(target) and owned(upload,receipt,target,owner,grant,same_grant))
        if not authority():return False
        if sample is None:return True
        state,_=upload.read();native=native_factory(target,grant,authority,seed_intent,max_gets=80)
        bridge=None
        try:
            baseline=native.observe(grant);version=native.version(grant)
            if not version or native.version(grant)!=version:raise ValueError('cb_native_thought/version')
            _seed_plan,native.body=prepare(owner,target,state['attempt'],sample,version,baseline)
            read=lambda:native.observe(grant)
            bridge=bridge_factory(command,owner,target,grant,seed_intent,thought_intent,authority,read,mock_port=mock_port)
            def seed_send(phase,body,permit):
                if phase=='delete_pending':bridge.finish()
                return native.send(phase,body,permit,grant)
            current['trial']=execute(owner,target,state['attempt'],sample,version,baseline,seed_intent,thought_intent,authority,
                read,seed_send,bridge.send,nonce=secrets.token_hex(16))
            if (native.posts!=2 or bridge.posts!=3 or not bridge.dry_verified or not bridge.completed or read()!=baseline):return False
            old=sample;current['sample']=None
            if not source(target):return False
            after=current['sample']
            return bool(authority() and after['source_raw_sha256']==old['source_raw_sha256']
                and after['chapter_uid']==old['chapter_uid'] and after['chapters']==old['chapters'] and after['baseline']==old['baseline'])
        except Exception:
            return bool(native.posts==0 and (bridge is None or bridge.posts==0) and seed_intent.read()[0] is None
                        and thought_intent.read()[0] is None and authority())
        finally:
            report['seed_posts']=native.posts
            if bridge is not None:
                report['native_thought_steps']=bridge.posts;report['dry_run_blocked']=bridge.dry_verified
                report['native_ui_completed']=bridge.completed;bridge.close()
    try:
        if any(store.read()[0] is not None for store in (journal,seed_intent,thought_intent)):raise ValueError('cb_native_thought/consumed')
        upload=upload_factory(journal,same_grant)
        result=uploader(upload,journal,grant,same_grant,source,apply=apply,cleanup_gate=trial)
        report['upload']=result;report['phase']=result.get('phase','unknown')
        if result.get('result')=='READ_ONLY_PREVIEW':report['result']='READ_ONLY_PREVIEW'
        elif result.get('result')=='EPUB_IMPORT_AND_SOURCE_VERIFIED' and current['trial'] and current['trial']['result']=='PASS':
            report.update(result='CB_NATIVE_THOUGHT_VERIFIED',fixture_removed=True,original_records_restored=True,no_replay=True)
    except Exception:report['result']='UNVERIFIED'
    finally:
        current['sample']=None
        if current['saved'] is not saved and saved:saved.clear()
        if current['saved']:current['saved'].clear()
    return report


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--apply',action='store_true');parser.add_argument('--runner',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
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
    print(json.dumps(report,ensure_ascii=False));return int(report['result'] not in ('READ_ONLY_PREVIEW','CB_NATIVE_THOUGHT_VERIFIED'))


if __name__=='__main__':raise SystemExit(main())
