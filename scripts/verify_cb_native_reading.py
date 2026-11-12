#!/usr/bin/env python3
"""One explicit CB_ shelf ordinal through native reading and offline reopen.

Default is offline. Private protocol data crosses captured pipes only, and
the existing Linux runner uses a disposable tmpfs profile. No data writes or
authentication POSTs are allowed. Every run independently rechecks position.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess

from secure_weread_session import COOKIE_NAMES, SessionStore
from verify_cb_reading import BASE, CbReadingProbe, baseline_position
from verify_cb_full_reading import CbFullReadingProbe
from verify_owner_reading import decode_envelope
from verify_translation_preflight import save_refreshed_web_session


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--book-index', type=int, choices=range(1, 9))
    parser.add_argument('--sync-limit',action='store_true')
    parser.add_argument('--full-book', action='store_true')
    parser.add_argument('--diagnostic-read-pacing', action='store_true',
                        help='Full-book diagnostic only: delay each native Reader/content read by one second')
    parser.add_argument('--progress-file', type=Path)
    parser.add_argument('--lua-command', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.sync_limit and (not args.saved_session or args.full_book):parser.error('--sync-limit requires single CB reading')
    if args.diagnostic_read_pacing and not (args.saved_session and args.full_book):
        parser.error('--diagnostic-read-pacing requires --saved-session --full-book')
    if args.progress_file and not (args.saved_session and args.full_book): parser.error('--progress-file requires --saved-session --full-book')
    if (bool(args.saved_session) != bool(args.lua_command)
            or args.saved_session and args.book_index is None or not args.saved_session and (args.book_index is not None or args.full_book)):
        parser.error('pair --saved-session, --book-index and --lua-command last')
    report = dict(result='OFFLINE_ONLY', checked_at=datetime.now(timezone.utc).isoformat(),
                  account_data_posts=0, authentication_posts=0, private_data_on_regular_disk=False, screenshots=0)
    if args.diagnostic_read_pacing: report.update(diagnostic_only=True, native_read_delay_seconds=1)
    saved = web = after = payload = envelope = None
    try:
        if args.saved_session:
            def progress(value):
                if args.progress_file: args.progress_file.write_text(json.dumps(value)+'\n')
            if args.sync_limit:
                from verify_cb_cloud_position import Web as CbSyncProbe
                from cb_sync_limit_contract import decode_envelope as decoder
            else:CbSyncProbe=CbReadingProbe;decoder=decode_envelope
            store, web = SessionStore(), (CbFullReadingProbe(progress=progress) if args.full_book else CbSyncProbe())
            saved = store.load(); web.vid = saved['vid']
            for key, value in saved['cookies'].items(): web.set_cookie(key, value)
            web.verify_account(); prepared = web.prepare(args.book_index); sample = prepared if args.full_book else prepared[0]; web.verify_account()
            report['preflight_rotation_saved'] = save_refreshed_web_session(store, saved, web)
            cookies = {cookie.name: cookie.value for cookie in web.cookies if cookie.name in COOKIE_NAMES
                       and cookie.domain in ('.weread.qq.com', 'weread.qq.com') and cookie.path == '/'}
            fresh = store.load()
            if fresh['vid'] != web.vid or fresh['cookies'] != cookies: raise ValueError('session_changed')
            saved.clear(); saved = fresh
            fields = ('book_id', 'chapter_uid', 'source_format', 'source_text', 'source_raw_sha256', 'source_sample_offset',
                      'shelf_ids', 'shelf_books')
            payload = {key: sample[key] for key in fields}
            payload.update(cb_reading=True, vid=web.vid, cookies=cookies)
            if args.sync_limit:payload['cb_sync_limit_preview']=True
            chapters=1
            if args.full_book:
                payload.update(cb_full_book=True,full_manifest=sample['full_manifest'],protected_resource_urls=sample['protected_resource_urls'])
                if args.diagnostic_read_pacing: payload['diagnostic_read_pacing']=True
                chapters=len(sample['full_manifest'])
            encoded = json.dumps(payload, ensure_ascii=False).encode()
            if len(encoded) > 256 * 1024: raise ValueError('input_limit')
            if args.full_book:progress(dict(phase='native',completed=chapters,total=chapters))
            child = subprocess.run(args.lua_command, input=encoded, capture_output=True, timeout=1100 if args.full_book else 360)
            envelope = decoder(child.stdout, web.vid, cb_reading=True,cb_full_book=args.full_book,full_chapters=chapters)
            report['ui'] = envelope['report']
            if any(stage['shelf_books'] != sample['shelf_books'] for stage in report['ui']['stages']):
                raise ValueError('native_scope_changed')
            if (args.full_book and report['ui']['result']=='PASS'
                    and report['ui']['full_book']['source_image_references']!=sum(row['image_references'] for row in sample['full_manifest'])):
                raise ValueError('native_scope_changed')
            after = CbReadingProbe(); after.vid = web.vid; after.book_id = web.book_id; after.allowed = {web.book_id}
            for key, value in envelope['cookies'].items(): after.set_cookie(key, value)
            after.verify_account()
            raw_after=after.request('progress_after', BASE + '/web/book/getProgress?bookId=' + web.book_id)
            observed = baseline_position(raw_after, web.book_id)
            if args.sync_limit:
                from cb_cloud_position import observed as snapshot
                report['full_cloud_state_unchanged']=snapshot(raw_after,web.book_id,sample['chapters'],'web')==snapshot(web.progress[(web.book_id,'progress_before')],web.book_id,sample['chapters'],'web')
                if not report['full_cloud_state_unchanged']:raise ValueError('native_scope_changed')
            after.verify_account()
            report['native_rotation_saved'] = save_refreshed_web_session(store, saved, after)
            report['cloud_position_unchanged'] = observed == sample['baseline']
            if child.returncode or report['ui']['result'] != 'PASS' or not report['cloud_position_unchanged']:
                raise ValueError('native_reading_unverified')
            report.update(result='CB_NATIVE_READING_VERIFIED', same_owner_verified=True, source_text_matched=True,
                          fresh_offline_process=True, source_format=sample['source_format'], source_shape=web.source_shape,
                          selected_ordinal=args.book_index)
            if args.full_book:report.update(full_book_verified=True,chapters=chapters)
            if args.diagnostic_read_pacing:
                report.update(result='CB_PACED_DIAGNOSTIC_VERIFIED',full_book_verified=False)
    except Exception:
        report.update(result='UNVERIFIED', reason='cb_native_reading_unverified')
    finally:
        for label, probe in [('preflight_stages', web), ('independent_after_stages', after)]:
            if probe:
                report[label] = [{key: row[key] for key in ('stage', 'status', 'api_code') if key in row} for row in probe.report['stages']]
                probe.samples.clear(); probe.close()
        for private in (saved, payload, envelope):
            if private: private.clear()
    print(json.dumps(report, indent=2))
    return 0 if report['result'] in {'OFFLINE_ONLY', 'CB_NATIVE_READING_VERIFIED', 'CB_PACED_DIAGNOSTIC_VERIFIED'} else 1


if __name__ == '__main__':
    raise SystemExit(main())
