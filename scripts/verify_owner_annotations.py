#!/usr/bin/env python3
"""Opt-in current-chapter annotations through plugin reading and offline reopen.

No cloud mutation or authentication POST. All private context crosses captured
memory pipes, and the native runner uses only a disposable tmpfs profile.
"""
import argparse
from datetime import datetime, timezone
import json
import subprocess

from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_owner_reading import BASE, ReadingPreflight, reading_position
from verify_translation_preflight import save_refreshed_web_session
from owner_annotation_contract import decode, prepare


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--lua-command', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if bool(args.saved_session) != bool(args.lua_command):
        parser.error('pair --saved-session and --lua-command; put --lua-command last')
    report = dict(result='OFFLINE_ONLY', checked_at=datetime.now(timezone.utc).isoformat(),
                  account_data_writes_attempted=0, authentication_posts_attempted=0,
                  private_data_on_regular_disk=False, screenshots=0)
    saved = grant = payload = envelope = web = None
    try:
        if args.saved_session:
            store, web = SessionStore(), ReadingPreflight()
            saved = store.load(); web.vid = saved['vid']
            for key, value in saved['cookies'].items(): web.set_cookie(key, value)
            web.verify_account()
            try: payload = web.prepare()
            finally:
                web.verify_account()
                report['preflight_rotation_saved'] = save_refreshed_web_session(store, saved, web)
                saved = store.load()
            grant = NativeSessionStore().load(web.vid)
            payload.update(vid=web.vid, cookies=saved['cookies'])
            payload['annotations'] = prepare(payload, grant)
            report.update(underlines=payload['annotations']['underlines'], thought_items=payload['annotations']['thought_items'])
            raw = json.dumps(payload, ensure_ascii=False).encode()
            if len(raw) > 256*1024: raise ValueError('annotations_input_limit')
            child = subprocess.run(args.lua_command, input=raw, capture_output=True, timeout=420)
            envelope = decode(child.stdout, web.vid)
            report['ui'] = envelope['report']
            web.cookies.clear()
            for key, value in envelope['cookies'].items(): web.set_cookie(key, value)
            web.verify_account()
            after = reading_position(web.request('progress_after', BASE+'/web/book/getProgress?bookId='+web.book_id), web.book_id)
            web.verify_account()
            report['native_rotation_saved'] = save_refreshed_web_session(store, saved, web)
            report['cloud_position_unchanged'] = after == web.baseline
            if child.returncode or envelope['report']['result'] != 'PASS' or not report['cloud_position_unchanged']:
                raise ValueError('annotations_ui_unverified')
            complete = all(stage['annotations']['located'] == stage['annotations']['underlines']
                           and stage['annotations']['partial'] == 0 for stage in envelope['report']['stages'])
            report.update(result='OWNER_NATIVE_ANNOTATIONS_VERIFIED' if complete else 'OWNER_NATIVE_ANNOTATIONS_PARTIAL',
                          complete_matching_verified=complete, same_owner_verified=True, fresh_offline_process=True)
    except Exception:
        report.update(result='UNVERIFIED', reason='owner_annotations_unverified')
    finally:
        if web:
            report['preflight_stages'] = [{k: row[k] for k in ('stage', 'status', 'api_code') if k in row} for row in web.report['stages']]
            web.shards.clear(); web.close()
        for value in (saved, grant, payload, envelope):
            if value: value.clear()
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report['result'] in ('OFFLINE_ONLY', 'OWNER_NATIVE_ANNOTATIONS_VERIFIED') else 1


if __name__ == '__main__':
    raise SystemExit(main())
