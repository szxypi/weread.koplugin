#!/usr/bin/env python3
"""Read-only inspection or one guarded restore of an interrupted UI trial.

Never resend an unacknowledged request. Recovery data stays in Keychain and
reports omit account identifiers, credentials, source text and offsets.
"""
import argparse
import hashlib
import json
import resource
import secrets
import time
from urllib.parse import urlencode

from native_txt_read_model import body
from readtime_upload_model import confirmed,guest_token,local_zone
from secure_native_direct_ui_trial import store_for
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from shelf_flag_change_contract import state_hash
from txt_full_summary import digest
from verify_eink_login import BASE
from verify_native_chapter_package import ChapterProbe
from verify_native_direct_roundtrip import Reads,catalog,check,current_source,state
from verify_translation_preflight import catalog as native_catalog,catalog_body
from verify_cloud_source_target import WebSourceProbe
from verify_web_source_progress import BASE as WEB


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--restore',action='store_true');parser.add_argument('--abort-prepared',action='store_true')
    parser.add_argument('--txt',action='store_true')
    modes=parser.add_mutually_exclusive_group();modes.add_argument('--timed',action='store_true');modes.add_argument('--closed',action='store_true')
    args=parser.parse_args(argv)
    if args.restore and args.abort_prepared or (args.restore or args.abort_prepared) and not args.saved_session:
        parser.error('invalid recovery mode')
    report=dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0,no_automatic_replay=True)
    if not args.saved_session:print(json.dumps(report));return 0
    saved=credentials=web=None;store=store_for(txt=args.txt,timed=args.timed,closed=args.closed);attempted=0;phase='intent'
    try:
        resource.setrlimit(resource.RLIMIT_CORE,(0,0));record,receipt=store.read()
        if not record:raise ValueError('direct_ui_recovery/no_intent')
        report['intent_phase']=record['phase'];plan=record['plan'];phase='credentials'
        if args.abort_prepared:
            if record['phase']!='prepared':raise ValueError('direct_ui_recovery/phase')
            store.advance(receipt,'prepared','aborted');report.update(result='PREPARED_ABORTED',intent_phase='aborted')
            return 0
        from verify_native_thought_trial import other_pending
        mode='closed' if args.closed else 'timed' if args.timed else 'manual'
        if other_pending(exclude_native_direct_ui=not args.txt and mode=='manual',
                exclude_native_direct_interval=not args.txt and mode=='timed',exclude_native_direct_close=not args.txt and mode=='closed',
                exclude_native_direct_txt=mode if args.txt else None):raise ValueError('direct_ui_recovery/other_pending')
        saved=SessionStore().load();credentials=NativeSessionStore().load(saved['vid'])
        if digest(saved['vid'])!=plan['owner_sha256'] or digest(credentials)!=plan['grant_sha256']:
            raise ValueError('direct_ui_recovery/grant')
        identity=plan['baseline']['book_id'];uid=plan['baseline']['chapter_uid'];phase='source'
        probe=ChapterProbe();probe.allowed={identity}
        info=probe.request('book',BASE+'/book/info?'+urlencode(dict(bookId=identity)),credentials=credentials)
        catalog_raw=probe.request('catalog',BASE+'/book/chapterInfos',catalog_body(identity),credentials=credentials)
        expected=native_catalog(catalog_raw,identity,info);sample=dict(book_id=identity,expected=expected)
        readable=[row for row in expected['chapters'] if str(row['uid'])==uid and row.get('free_or_owned')]
        if expected['format']!=('txt' if args.txt else 'epub') or expected['version']!=plan['version'] or len(readable)!=1:
            raise ValueError('direct_ui_recovery/source')
        web=WebSourceProbe();web.vid=saved['vid']
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();web.book_id=identity;web.chapter=uid
        raw=current_source(sample,uid,credentials,web)
        if hashlib.sha256(raw).hexdigest()!=plan['source_sha256'] \
                or catalog(web,identity,uid,plan['baseline']['chapter_idx'])!=plan['catalog_sha256']:
            raise ValueError('direct_ui_recovery/source')
        native=Reads(credentials,identity,restore_only=True)
        native_shelf=state_hash(native.request('shelf',BASE+'/shelf/sync',credentials=credentials))
        web_shelf=state_hash(web.request('shelf',WEB+'/web/shelf/sync'))
        if native_shelf!=plan['shelf_sha256']:raise ValueError('direct_ui_recovery/shelf')
        observed,counts=state(native.request('progress',BASE+'/book/getProgress?'+urlencode(dict(bookId=identity)),credentials=credentials),identity,'native')
        if observed not in (plan['baseline'],plan['target']) or counts!=plan['counts']:
            raise ValueError('direct_ui_recovery/changed')
        for _ in range(2):check(web,native,credentials,identity,observed,counts,native_shelf,web_shelf,both_counts=args.txt)
        report.update(result='READ_ONLY_INSPECTED',current_state='original' if observed==plan['baseline'] else 'target',
            source_and_two_channel_state_verified=True)
        if not args.restore:return 0
        phase='restore'
        if record['phase']=='restore_acknowledged':
            if observed!=plan['baseline']:raise ValueError('direct_ui_recovery/changed')
            store.advance(receipt,'restore_acknowledged','retired')
            report.update(result='RESTORE_READBACK_VERIFIED',intent_phase='retired');return 0
        if record['phase'] not in ('advance_acknowledged','advance_verified') or observed!=plan['target']:
            raise ValueError('direct_ui_recovery/phase')
        if record['phase']=='advance_acknowledged':receipt=store.advance(receipt,'advance_acknowledged','advance_verified')
        guest,_=guest_token(native.request('feature',BASE+'/feature?synckey=0',credentials=credentials))
        request=body(credentials,plan['baseline'],plan['version'],guest,int(time.time()),secrets.randbelow(1000),local_zone())
        native.pending=digest(request)
        def claim():
            nonlocal receipt,attempted
            receipt=store.advance(receipt,'advance_verified','restore_pending');attempted=1
        native.claim=claim
        ack=native.request('native_txt_restore',BASE+'/book/read',body=request,credentials=credentials)
        if not confirmed(ack):raise ValueError('direct_ui_recovery/ack')
        receipt=store.advance(receipt,'restore_pending','restore_acknowledged')
        for attempt in range(4):
            if check(web,native,credentials,identity,plan['baseline'],counts,native_shelf,web_shelf,
                     previous=plan['target'],both_counts=args.txt):break
            if attempt<3:time.sleep(1)
        else:raise ValueError('direct_ui_recovery/readback_pending')
        store.advance(receipt,'restore_acknowledged','retired')
        report.update(result='ORIGINAL_RESTORED',intent_phase='retired',explicit_success_receipt=True)
    except (Exception,KeyboardInterrupt) as error:
        report.update(result='UNVERIFIED',phase=phase)
        if isinstance(error,ValueError) and str(error).startswith('direct_ui_recovery/'):
            report['reason']=str(error)
    finally:
        report['account_data_posts']=attempted
        if web:web.close()
        if saved:saved.clear()
        if credentials:credentials.clear()
        print(json.dumps(report))
    return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
