#!/usr/bin/env python3
"""Explicit real owner UI expiry check; optional one parent renewal.

Offline by default. Saved-session mode alone cannot authorize a login POST.
--renew-in-parent first persists a Keychain intent, then permits at most one
guarded Lua login. Unknown receipts are never replayed. All credentials and
private annotation models cross captured pipes only, never argv or files.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import subprocess

from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_owner_reading import BASE, ReadingPreflight, reading_position
from verify_eink_login import BASE as NATIVE_BASE, NativeProbe
from verify_translation_preflight import save_refreshed_web_session
from fetch_weread_epub import decode_content_shards
from owner_annotation_contract import prepare
from owner_recovery_contract import decode, compare_postflight


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--renew-in-parent', action='store_true')
    parser.add_argument('--lua-command', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if bool(args.saved_session) != bool(args.lua_command) or args.renew_in_parent and not args.saved_session:
        parser.error('pair --saved-session and --lua-command; renewal requires both; put --lua-command last')
    report = dict(result='OFFLINE_ONLY', checked_at=datetime.now(timezone.utc).isoformat(),
                  account_data_writes_attempted=0, authentication_posts_attempted=0,
                  private_data_on_regular_disk=False, screenshots=0, keychain_intent_retained=False)
    saved = grant = payload = envelope = web = receipt = native_store = None
    try:
        if args.saved_session:
            store, web = SessionStore(), ReadingPreflight()
            saved = store.load(); web.vid = saved['vid']
            for key,value in saved['cookies'].items(): web.set_cookie(key,value)
            web.verify_account()
            try: payload = web.prepare()
            finally:
                web.verify_account()
                report['preflight_rotation_saved'] = save_refreshed_web_session(store,saved,web)
                saved = store.load()
            native_store = NativeSessionStore()
            grant = native_store.load(web.vid)
            raw_source = decode_content_shards(*(web.shards[key] for key in ('e_0','e_1','e_3')))
            payload.update(vid=web.vid,cookies=saved['cookies'],annotations=dict(credentials=grant,
                permit_renewal=args.renew_in_parent,intent_digest=''))
            if args.renew_in_parent:
                receipt,grant = native_store.begin_renewal(web.vid,grant)
                payload['annotations']['intent_digest'] = hashlib.sha256(receipt.pending).hexdigest()
                report.update(keychain_intent_readback_verified=True,keychain_intent_retained=True)
                report['authentication_posts_attempted'] = None # unknown until a trusted guarded receipt
            raw = json.dumps(payload,ensure_ascii=False).encode()
            if len(raw) > 256*1024: raise ValueError('recovery_input_limit')
            child = subprocess.run(args.lua_command,input=raw,capture_output=True,timeout=420)
            envelope = decode(child.stdout,web.vid)
            report['ui'] = envelope['report']
            private = envelope['recovery_private']
            if not private: raise ValueError('recovery_no_private_receipt')
            live = private[0]; stats = live['recovery']
            report['authentication_posts_attempted'] = stats['authentication_posts']
            report['native_recovery'] = stats
            if not args.renew_in_parent and stats['authentication_posts']:
                raise ValueError('recovery_unapproved_authentication')
            if receipt and stats['saved_new_grant']:
                renewed = live['credentials']
                verifier = NativeProbe()
                shelf = verifier.request('independent_renewed_shelf',NATIVE_BASE+'/shelf/sync',credentials=renewed)
                if not isinstance(shelf.get('books'),list) or not 1 <= len(shelf['books']) <= 5000:
                    raise ValueError('recovery_shelf_unverified')
                web.verify_account()
                native_store.finish_renewal(receipt,renewed,verified=True)
                if native_store.load(web.vid) != renewed: raise ValueError('recovery_keychain_readback')
                receipt = None
                report.update(keychain_renewed_readback_verified=True,keychain_intent_retained=False,
                              same_owner_verified=True,independent_shelf_books=len(shelf['books']))
            elif receipt and stats['authentication_posts'] == 0:
                native_store.release_renewal(receipt,not_dispatched=True)
                receipt = None
                report.update(keychain_intent_retained=False,proved_no_authentication_dispatch=True)
            web.cookies.clear()
            for key,value in envelope['cookies'].items(): web.set_cookie(key,value)
            web.verify_account()
            after = reading_position(web.request('progress_after',BASE+'/web/book/getProgress?bookId='+web.book_id),web.book_id)
            report['cloud_position_unchanged'] = after == web.baseline
            report['native_rotation_saved'] = save_refreshed_web_session(store,saved,web)
            if not report['cloud_position_unchanged']: raise ValueError('recovery_progress_changed')
            if not args.renew_in_parent:
                stage = report['ui']['stages'][0]
                if (stats['first_native_status'] != 401 or stats['authentication_posts'] or stats['guard_denied']
                        or stats['store_write_attempts'] != 1 or not stage['plugin_selection'] or not stage['native_reader']
                        or not stage['source_receipt_verified'] or not report['ui']['profile_removed']):
                    raise ValueError('recovery_expiry_unverified')
                report['result'] = 'OWNER_PLUGIN_EXPIRY_VERIFIED_NO_AUTH_POST'
            else:
                if not report.get('keychain_renewed_readback_verified') or child.returncode or report['ui']['result'] != 'PASS':
                    raise ValueError('recovery_ui_unverified')
                expected = prepare(payload,live['credentials'],raw_source)
                compare_postflight(live['model'],expected)
                if any(stage['annotations']['located'] != stage['annotations']['underlines'] or stage['annotations']['partial']
                       for stage in report['ui']['stages']):
                    raise ValueError('recovery_matching_incomplete')
                report.update(result='OWNER_PARENT_ANNOTATION_RECOVERY_VERIFIED',independent_model_verified=True,
                              independent_source_quotes_verified=True,model_validation_phase='host_postflight',fresh_offline_process=True)
    except Exception:
        report.update(result='UNVERIFIED',reason='owner_parent_recovery_unverified')
    finally:
        if receipt is not None: report['keychain_intent_retained'] = True
        if web:
            report['preflight_stages'] = [{k:row[k] for k in ('stage','status','api_code') if k in row} for row in web.report['stages']]
            web.shards.clear(); web.close()
        for value in (saved,grant,payload,envelope):
            if value: value.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2))
    return 0 if report['result'] in ('OFFLINE_ONLY','OWNER_PLUGIN_EXPIRY_VERIFIED_NO_AUTH_POST','OWNER_PARENT_ANNOTATION_RECOVERY_VERIFIED') else 1


if __name__ == '__main__': raise SystemExit(main())
