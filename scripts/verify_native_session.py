#!/usr/bin/env python3
"""Save/reuse owner-approved native QR authorization without credential files.

Default is offline. Interactive save requires the owner VID from the existing
approved Web Keychain item; a different scanned account is never saved.
Only native authorization and a read-only shelf check are performed.
"""
import argparse
from datetime import datetime,timezone
import json
from pathlib import Path
import tempfile
from urllib.parse import urlencode
import webbrowser

from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore,StoreError
from verify_eink_login import BASE,NativeProbe,ProbeError


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    modes=parser.add_mutually_exclusive_group()
    modes.add_argument('--interactive',action='store_true')
    modes.add_argument('--saved-session',action='store_true')
    modes.add_argument('--clear-saved-session',action='store_true')
    parser.add_argument('--save-session',action='store_true')
    parser.add_argument('--output',type=Path)
    args=parser.parse_args(argv)
    if args.save_session and not args.interactive:parser.error('--save-session requires --interactive')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),credentials_written_to_files=False,account_data_writes_attempted=0)
    probe=None;credentials=None
    try:
        if args.clear_saved_session:
            NativeSessionStore().delete()
            report['result']='NATIVE_SESSION_CLEARED'
        if args.interactive or args.saved_session:
            owner=SessionStore().load()['vid']
            probe=NativeProbe()
            if args.interactive:
                import qrcode
                uid=probe.create_qr()
                with tempfile.TemporaryDirectory(prefix='weread-native-owner-') as root:
                    path=Path(root)/'scan.png'
                    qrcode.make('https://open.weixin.qq.com/connect/confirm?'+urlencode(dict(uuid=uid))).save(path)
                    path.chmod(0o600)
                    if not webbrowser.open(path.as_uri()):raise ProbeError('local_qr_unavailable')
                    print('QR_READY: scan the local image; verified native access will be retained in macOS Keychain.',flush=True)
                    credentials,shelf=probe.finish(probe.wait_for_code(uid))
                if credentials['vid']!=owner:raise StoreError('native_owner_mismatch')
                if args.save_session:
                    NativeSessionStore().save(credentials,owner,verified=True)
                    report.update(native_session_saved=True,keychain_readback_verified=True)
            else:
                credentials=NativeSessionStore().load(owner)
                shelf=probe.request('shelf_reuse',BASE+'/shelf/sync',credentials=credentials)
                if not isinstance(shelf.get('books'),list):raise ProbeError('native_shelf_invalid')
                report['native_session_reused']=True
            report.update(result='NATIVE_SESSION_VERIFIED',same_owner_verified=True,book_count=len(shelf['books']),stages=probe.report['stages'])
            shelf.clear()
    except (StoreError,ProbeError) as exc:report.update(result='UNVERIFIED',reason=str(exc))
    except Exception:report.update(result='UNVERIFIED',reason='native_verification_failed')
    finally:
        if credentials:credentials.clear()
    data=json.dumps(report,ensure_ascii=False,indent=2)+'\n'
    if args.output:args.output.write_text(data)
    print(data,end='')
    return 1 if report['result']=='UNVERIFIED' else 0


if __name__=='__main__':raise SystemExit(main())
