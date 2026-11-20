#!/usr/bin/env python3
"""Real native membership UI preview, or an explicitly authorized two-POST test.

Default offline. Saved-session mode is read-only unless --apply, the matching
--expected-plan and the separately armed Lua runner are all supplied. Private
input/diagnostics cross captured pipes only; reports contain counts and flags.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import re
import subprocess
from urllib.parse import urlencode

from owner_shelf_membership_contract import decode_runner
from secure_native_session import NativeSessionStore
from secure_shelf_experiment import ShelfExperimentStore,canonical,fingerprint
from secure_weread_session import SessionStore
from verify_native_metadata import normalize_native
from verify_eink_login import BASE
from verify_eink_shelf_write import snapshot
from verify_native_discovery import DiscoveryProbe,page


def members_digest(members):
    parts=[]
    for identity in sorted(members):
        if not isinstance(identity,str) or not identity or len(identity.encode())>256:raise ValueError('membership_identity')
        parts.append(str(len(identity.encode())).encode()+b':'+identity.encode())
    return hashlib.sha256(b''.join(parts)).hexdigest()


def prepare(credentials,probe):
    rows=snapshot(probe.request('discovery_shelf',BASE+'/shelf/sync',credentials=credentials))
    source=probe.request('search',BASE+'/store/search?'+urlencode(dict(keyword='三体',scope=10,maxIdx=0,count=20)),credentials=credentials)
    target=next((row for row in page('search',source)['books'] if row['title']=='三体1' and '刘慈欣' in row['author'] and row['bookId'] not in rows),None)
    if target is None:raise ValueError('membership_target_unavailable')
    identity=target['bookId']
    metadata=normalize_native(probe.request('discovery_metadata',BASE+'/book/info?'+urlencode(dict(bookId=identity)),credentials=credentials),identity)
    if metadata['title']!=target['title'] or '刘慈欣' not in metadata.get('author',''):raise ValueError('membership_target_changed')
    bound=dict(owner=credentials['vid'],book_id=identity,members_sha256=members_digest(rows),grant_sha256=hashlib.sha256(canonical(credentials)).hexdigest())
    payload=dict(credentials=credentials,book_id=identity,expected_metadata=metadata,shelf_books=len(rows),members_digest=bound['members_sha256'])
    return bound,payload


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--apply',action='store_true')
    parser.add_argument('--expected-plan')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if (bool(args.saved_session)!=bool(args.lua_command) or args.apply and (not args.saved_session or not isinstance(args.expected_plan,str)
            or not re.fullmatch('[a-f0-9]{64}',args.expected_plan)) or args.expected_plan and not args.apply):
        parser.error('saved-session needs --lua-command last; --apply also needs its exact --expected-plan')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_writes_attempted=0,
                authentication_posts_attempted=0,private_data_on_regular_disk=False,screenshots=0,intent_state='none',real_plugin_write_verified=False)
    credentials=probe=payload=envelope=receipt=intents=None
    try:
        if args.saved_session:
            owner=SessionStore().load()['vid'];credentials=NativeSessionStore().load(owner)
            intents=ShelfExperimentStore();pending=intents.pending();report['pending_intent_present']=pending
            if pending:report['intent_state']='pending'
            if args.apply and pending:raise ValueError('shelf_experiment_unconfirmed')
            probe=DiscoveryProbe();bound,payload=prepare(credentials,probe);digest=fingerprint(bound)
            report.update(plan_fingerprint=digest,planned_post_limit=2,same_owner_verified=True,python_preflight_gets=3)
            if args.apply and digest!=args.expected_plan:raise ValueError('shelf_plan_changed')
            intent_digest=''
            if args.apply:
                report['intent_state']='unknown'
                receipt=intents.begin(bound);intent_digest=hashlib.sha256(receipt.pending).hexdigest()
                report.update(intent_state='pending',intent_readback_verified=True,account_data_writes_attempted=None)
            payload.update(permit_writes=args.apply,plan_fingerprint=digest,intent_digest=intent_digest)
            encoded=json.dumps(payload,ensure_ascii=False).encode()
            if len(encoded)>256*1024:
                if receipt is not None:
                    intents.finish(receipt,not_dispatched=True);receipt=None;report['intent_state']='cleared'
                report['account_data_writes_attempted']=0;raise ValueError('membership_input_limit')
            try:child=subprocess.run(args.lua_command,input=encoded,capture_output=True,timeout=210)
            except FileNotFoundError:
                if receipt is not None:
                    intents.finish(receipt,not_dispatched=True);receipt=None;report['intent_state']='cleared'
                report['account_data_writes_attempted']=0;raise
            envelope=decode_runner(child.stdout,args.apply);report['ui']=envelope['report']
            stage=envelope['report']['stage'];private=envelope['private']
            if (stage is None or private['plan_fingerprint']!=digest or private['intent_digest']!=intent_digest
                    or stage['shelf_books']!=payload['shelf_books']):raise ValueError('membership_receipt_unverified')
            counts=stage['request_counts'];report['account_data_writes_attempted']=counts[2]+counts[3]
            after=snapshot(probe.request('discovery_shelf',BASE+'/shelf/sync',credentials=credentials))
            restored=members_digest(after)==bound['members_sha256'] and len(after)==payload['shelf_books'] and payload['book_id'] not in after
            report.update(independent_membership_unchanged=restored,final_shelf_count=len(after))
            if args.apply and report['account_data_writes_attempted']==0:
                intents.finish(receipt,not_dispatched=True);receipt=None;report['intent_state']='cleared'
            elif args.apply and stage['roundtrip_restored'] and restored and stage['post_statuses']==[200,200] and private['final_members_digest']==bound['members_sha256']:
                intents.finish(receipt,restored_verified=True);receipt=None;report['intent_state']='cleared'
            if (child.returncode or envelope['report']['result']!='PASS' or not restored
                    or private['final_members_digest']!=bound['members_sha256']):raise ValueError('membership_native_unverified')
            if args.apply and (report['account_data_writes_attempted']!=2 or report['intent_state']!='cleared'):raise ValueError('membership_roundtrip_unverified')
            report.update(result='OWNER_NATIVE_MEMBERSHIP_ROUNDTRIP_VERIFIED' if args.apply else 'OWNER_NATIVE_MEMBERSHIP_PREVIEW_VERIFIED',
                          real_plugin_write_verified=args.apply)
    except KeyboardInterrupt:report.update(result='UNVERIFIED',reason='membership_interrupted')
    except Exception as exc:
        report.update(result='UNVERIFIED',reason='membership_verification_failed')
        known={'shelf_experiment_unconfirmed','shelf_plan_changed','shelf_intent_readback_failed','shelf_intent_cleanup_unverified',
               'membership_receipt_unverified','membership_native_unverified','membership_target_unavailable','membership_target_changed'}
        if str(exc) in known:report['detail']=str(exc)
    finally:
        if receipt is not None and report['intent_state']!='unknown':report['intent_state']='pending'
        if probe:report['preflight_stages']=[{key:row[key] for key in ('stage','status','api_code') if key in row} for row in probe.report['stages']]
        for value in (credentials,payload,envelope):
            if value:value.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2))
    return 0 if report['result'] in ('OFFLINE_ONLY','OWNER_NATIVE_MEMBERSHIP_PREVIEW_VERIFIED','OWNER_NATIVE_MEMBERSHIP_ROUNDTRIP_VERIFIED') else 1


if __name__=='__main__':raise SystemExit(main())
