#!/usr/bin/env python3
"""Read-only saved-shelf membership prototype; offline by default.

Only the existing Web owner/shelf GETs are used. Real identities stay in
captured memory pipes; the absent control is synthetic, not a real test book.
"""
import argparse
from datetime import datetime, timezone
import json
import subprocess

from secure_weread_session import SessionStore
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE, WebSourceProbe, identifier
from web_shelf_contract import normalize


def project(shelf):
    books = normalize(shelf)['books']
    ids = [book['bookId'] for book in books]
    absent = 'membership-absent-control'
    suffix = 0
    while absent in ids:
        suffix += 1
        absent = 'membership-absent-control-' + str(suffix)
    selected = ids[:8] + [absent]
    return dict(books=[dict(bookId=value) for value in ids], selected=selected), [value in ids for value in selected]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--lua-command', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.lua_command and not args.saved_session:
        parser.error('Lua comparison requires --saved-session; --lua-command must be last')
    report = dict(result='OFFLINE_ONLY', checked_at=datetime.now(timezone.utc).isoformat(),
                  account_data_writes=0, authentication_posts=0, private_identities_saved=False,
                  credentials_sent_to_lua=False, absent_control_is_synthetic=True)
    if not args.saved_session:
        print(json.dumps(report, indent=2))
        return 0
    probe, saved = WebSourceProbe(), {}
    try:
        store = SessionStore()
        saved = store.load()
        probe.vid = identifier(saved['vid'])
        for name, value in saved['cookies'].items():
            probe.set_cookie(name, value)
        probe.verify_account()
        sample, expected = project(probe.request('shelf', BASE + '/web/shelf/sync'))
        report['web_cookie_rotation_saved'] = save_refreshed_web_session(store, saved, probe)
        report.update(owner_verified=True, shelf_books=len(sample['books']),
                      positive_samples=sum(expected), absent_samples=expected.count(False))
        if args.lua_command:
            child = subprocess.run(args.lua_command, input=json.dumps(sample).encode(), capture_output=True, timeout=60)
            frame = b'\nWEREAD_MEMBERSHIP_RESULT='
            if child.returncode or len(child.stdout) > 65536 or child.stdout.count(frame) != 1:
                raise ValueError('membership_probe_failed')
            actual = json.loads(child.stdout.split(frame)[1])
            if (not isinstance(actual, list) or len(actual) != len(expected)
                    or any(type(value) is not bool for value in actual) or actual != expected):
                raise ValueError('membership_projection_mismatch')
            report['lua_membership_projection_matches'] = True
        report['result'] = 'SHELF_MEMBERSHIP_READ_VERIFIED'
    except Exception:
        report.update(result='UNVERIFIED', reason='shelf_membership_verification_failed')
    finally:
        report['stages'] = probe.report['stages']
        saved.clear()
        probe.close()
    print(json.dumps(report, indent=2))
    return 0 if report['result'] == 'SHELF_MEMBERSHIP_READ_VERIFIED' else 1


if __name__ == '__main__':
    raise SystemExit(main())
