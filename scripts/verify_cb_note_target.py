#!/usr/bin/env python3
"""Verify one imported-book highlight against its source and native reader.

Offline by default. The opt-in path only reads a shelf-selected mark, its
chapter and position. Raw note text and credentials stay in memory or a
disposable native tmpfs profile; the report contains counts and flags only.
"""
import argparse
from datetime import datetime, timezone
import json
import subprocess
import time
from unittest.mock import patch

from my_cloud_marks_model import project as marks_project
from my_mark_target import project as target_project
from my_mark_span import project as span_project
from run_my_mark_navigation_ui import FRAME, public_report, validate
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_cb_personal_notes import CbNotesProbe
from verify_cb_progress import cb_ids
from verify_cb_reading import CbReadingProbe
from verify_translation_preflight import save_refreshed_web_session


class NativeUiFailure(ValueError):
    def __init__(self, report):
        super().__init__('cb_note_target/native')
        self.report = public_report(report)


def choose_chapter(chapters, _baseline, uid):
    selected = [row for row in chapters if str(row.get('chapterUid')) == uid]
    if len(selected) != 1:
        raise ValueError('cb_note_target/chapter')
    return selected[0]


def read_source(saved, store, ids, identity, uid):
    web = CbReadingProbe()
    try:
        web.vid = saved['vid']
        for key, value in saved['cookies'].items():
            web.set_cookie(key, value)
        web.verify_account()
        with patch('verify_cb_reading.choose_chapter', side_effect=lambda chapters, baseline: choose_chapter(chapters, baseline, uid)):
            samples = web.prepare(ids.index(identity) + 1, expected_book_id=identity)
        if web.allowed != set(ids) or len(samples) != 1 or samples[0]['chapter_uid'] != uid:
            raise ValueError('cb_note_target/scope')
        sample = samples[0]
        if sample['source_format'] != 'web_xhtml' or not all(web.last_checks.values()):
            raise ValueError('cb_note_target/source')
        web.verify_account()
        rotated = save_refreshed_web_session(store, saved, web)
        return sample, rotated
    finally:
        web.samples.clear()
        web.close()


def native_ui(command, payload, width, height, dpi, *, personal=False):
    args = list(command) + ['--width', str(width), '--height', str(height), '--dpi', str(dpi)]
    if personal:
        args.append('--personal-display')
    data = json.dumps(payload, ensure_ascii=False).encode()
    if len(data) > 12 * 1024 * 1024:
        raise ValueError('cb_note_target/input')
    child = subprocess.run(args, input=data, capture_output=True, timeout=360)
    if len(child.stdout) > 512 * 1024 or child.stdout.count(FRAME) != 1:
        raise ValueError('cb_note_target/native')
    result = json.loads(child.stdout.split(FRAME)[1])
    if child.returncode or result.get('result') != 'PASS' or result.get('profile_removed') is not True \
            or result.get('installed_bytes_match') is not True or not isinstance(result.get('stages'), list) \
            or len(result['stages']) != 2:
        raise NativeUiFailure(result)
    try:
        for stage, mode in zip(result['stages'], ('live', 'reopen')):
            validate(stage, mode, 1, 1, personal=personal)
    except ValueError:
        raise NativeUiFailure(result) from None
    return dict(width=width, height=height, located=1, fresh_offline_reopen=True,
                plugin_http_requests=0, profile_removed=True, personal_display_verified=personal)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--personal-display', action='store_true')
    parser.add_argument('--native-command', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.personal_display and not args.native_command:
        parser.error('personal display requires a native command')
    if args.native_command and not args.saved_session:
        parser.error('native UI requires --saved-session')
    report = dict(result='OFFLINE_ONLY', checked_at=datetime.now(timezone.utc).isoformat(),
                  account_data_posts=0, authentication_posts=0, private_values_in_report=False)
    saved = credentials = first = second = None
    try:
        if args.saved_session:
            store = SessionStore(); saved = store.load()
            credentials = NativeSessionStore().load(saved['vid'])
            native = CbNotesProbe(); ids = cb_ids(native.shelf(credentials)); native.ids = set(ids)
            now = int(time.time()); selected = []
            for identity in ids:
                model = marks_project(native.read('marks', identity, credentials), identity, credentials['vid'], now)
                for row in model['updated']:
                    if row.get('type') == 1 and row.get('markText') and type(row.get('chapterUid')) is int \
                            and row['chapterUid'] > 0 and isinstance(row.get('range'), str):
                        selected.append((identity, row, model))
            if not selected:
                raise ValueError('cb_note_target/no_sample')
            identity, row, model = selected[0]
            uid = str(row['chapterUid'])
            first, rotated1 = read_source(saved, store, ids, identity, uid)
            if rotated1:
                saved.clear(); saved = store.load()
            second, rotated2 = read_source(saved, store, ids, identity, uid)
            if rotated2:
                saved.clear(); saved = store.load()
            if first['source'] != second['source'] or first['chapters'] != second['chapters'] \
                    or first['baseline'] != second['baseline']:
                raise ValueError('cb_note_target/source_changed')
            expected = target_project(second['source'], identity, uid, row)
            if args.personal_display:
                span = span_project(second['source'], identity, uid, row)
                if span['first'] != expected['chapter_offset'] or span['last'] <= span['first']:
                    raise ValueError('cb_note_target/span')
            report.update(imported_books=len(ids), matching_highlights=len(selected), source_reads=2,
                          quote_matches_source=True, source_and_position_unchanged=True,
                          cookie_rotation_saved=rotated1 or rotated2)
            if args.native_command:
                payload = dict(book_id=identity, owner=credentials['vid'], model=model,
                               chapters=[dict(chapter_uid=uid, raw=second['source'], rows=[row], targets=[expected])])
                report['native_ui'] = [native_ui(args.native_command, payload, width, height, dpi, personal=args.personal_display)
                                       for width, height, dpi in ((600, 800, 167), (1264, 1680, 300))]
            final_native = CbNotesProbe(); final_native.ids = {identity}
            latest = marks_project(final_native.read('marks', identity, credentials), identity, credentials['vid'], now)
            if latest != model or cb_ids(native.shelf(credentials)) != ids:
                raise ValueError('cb_note_target/changed')
            report.update(result='CB_NOTE_TARGET_VERIFIED', marks_unchanged=True, shelf_identity_unchanged=True)
    except NativeUiFailure as error:
        report.update(result='UNVERIFIED', reason='cb_note_target_native_unverified', native_diagnostic=error.report)
    except Exception:
        report.update(result='UNVERIFIED', reason='cb_note_target_verification_failed')
    finally:
        if first: first.clear()
        if second: second.clear()
        if credentials: credentials.clear()
        if saved: saved.clear()
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report['result'] in ('OFFLINE_ONLY', 'CB_NOTE_TARGET_VERIFIED') else 1


if __name__ == '__main__':
    raise SystemExit(main())
