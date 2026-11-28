#!/usr/bin/env python3
"""Explicit, once-only saved native authorization renewal with Keychain intent.

Default is offline. --saved-session alone only reads the shelf. --renew also
persists an unconfirmed marker before one authentication POST, verifies its
owner/shelf, and saves the new grant. Unknown receipts block future reuse;
there is no automatic POST replay or account data write.
"""
import argparse
from datetime import datetime,timezone
import json
import subprocess

from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore,StoreError
from verify_eink_login import BASE,ProbeError
from verify_eink_renewal import RenewalProbe


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--renew',action='store_true')
    parser.add_argument('--lua-expiry-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if args.renew and not args.saved_session or args.lua_expiry_command and not args.renew:
        parser.error('renewal requires --saved-session; optional --lua-expiry-command requires --renew and must be last')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_writes_attempted=0,
                authentication_posts_attempted=0,credentials_written_to_files=False)
    probe=receipt=previous=renewed=None
    try:
        if args.saved_session:
            owner=SessionStore().load()['vid']
            store=NativeSessionStore()
            previous=store.load(owner)
            if args.lua_expiry_command:
                child=subprocess.run(args.lua_expiry_command,input=json.dumps(dict(credentials=previous)).encode(),capture_output=True,timeout=45)
                frame=b'\nWEREAD_NATIVE_EXPIRY_RESULT='
                if child.returncode or len(child.stdout)>256*1024 or child.stdout.count(frame)!=1:raise StoreError('native_expiry_probe_failed')
                value=json.loads(child.stdout.split(frame)[1])
                if value!=dict(native_expired=True,http_status=401,requests=1):raise StoreError('native_expiry_not_observed')
                report['native_lua_http_401_observed']=True
            probe=RenewalProbe()
            if args.renew:
                receipt,previous=store.begin_renewal(owner,previous)
                report['keychain_pending_readback_verified']=True
                renewed,shelf=probe.renew(previous)
                store.finish_renewal(receipt,renewed,verified=True)
                if store.load(owner)!=renewed:raise StoreError('native_keychain_readback_mismatch')
                report.update(result='SAVED_NATIVE_RENEWAL_VERIFIED',same_owner_verified=True,book_count=len(shelf['books']),
                              keychain_renewed_readback_verified=True,access_token_changed=renewed['accessToken']!=previous['accessToken'],
                              refresh_token_returned=probe.report.get('refresh_token_returned'))
            else:
                shelf=probe.request('saved_shelf',BASE+'/shelf/sync',credentials=previous)
                if not isinstance(shelf.get('books'),list):raise ProbeError('saved_shelf: invalid snapshot')
                report.update(result='SAVED_NATIVE_ACCESS_VERIFIED',book_count=len(shelf['books']))
    except (StoreError,ProbeError) as exc:report.update(result='UNVERIFIED',reason=str(exc))
    except KeyboardInterrupt:report.update(result='CANCELLED',reason='native_renewal_interrupted')
    except Exception:report.update(result='UNVERIFIED',reason='saved_native_renewal_failed')
    finally:
        attempted=probe.report.get('renewal_attempts',0) if probe else 0
        report['authentication_posts_attempted']=attempted
        if receipt and attempted==0:
            try:store.release_renewal(receipt,not_dispatched=True)
            except StoreError:pass
        if probe:report['stages']=probe.report['stages']
        if previous:previous.clear()
        if renewed:renewed.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2))
    return 0 if report['result'] in ('OFFLINE_ONLY','SAVED_NATIVE_RENEWAL_VERIFIED','SAVED_NATIVE_ACCESS_VERIFIED') else 1


if __name__=='__main__':raise SystemExit(main())
