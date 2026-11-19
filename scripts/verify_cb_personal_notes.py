#!/usr/bin/env python3
"""Read-only imported-book personal notes, with optional native UI comparison.

Default is offline. Raw notes, identities and credentials remain in memory or
the native runner's disposable tmpfs profile; only counts and booleans leave.
"""
import argparse
from datetime import datetime, timezone
import json
import subprocess
import time
from urllib.parse import urlencode

from my_cloud_marks_model import project
from my_cloud_thoughts_model import complete
from run_my_cloud_marks_ui import FRAME, validate_stage
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_cb_progress import cb_id, cb_ids
from verify_eink_login import BASE, NativeProbe


class CbNotesProbe(NativeProbe):
    def __init__(self):
        super().__init__()
        self.ids = set()
        self.used = set()
        self.shelves = 0

    def request(self, *_args, **_kwargs):
        raise ValueError('cb_notes/scope')

    def shelf(self, credentials):
        if self.shelves >= 2:
            raise ValueError('cb_notes/scope')
        self.shelves += 1
        return super().request('shelf', BASE + '/shelf/sync', credentials=credentials)

    def read(self, kind, identity, credentials):
        if not cb_id(identity) or identity not in self.ids or (kind, identity) in self.used:
            raise ValueError('cb_notes/scope')
        if kind == 'marks':
            path, query = '/book/bookmarklist', {'bookId': identity, 'synckey': 0}
        elif kind == 'thoughts':
            path, query = '/review/list', {'bookId': identity, 'listType': 11, 'listMode': 0,
                                          'mine': 1, 'synckey': 0, 'count': 20}
        else:
            raise ValueError('cb_notes/scope')
        self.used.add((kind, identity))
        return super().request(kind, BASE + path + '?' + urlencode(query), credentials=credentials)


def native_ui(command, source, identity, owner, credentials, now, variant, expected, width, height, dpi):
    payload = dict(source=source, book_id=identity, owner=owner, now=now, credentials=credentials)
    if variant:
        payload['variant'] = variant
    args = list(command) + ['--width', str(width), '--height', str(height), '--dpi', str(dpi)]
    if variant:
        args += ['--variant', variant]
    child = subprocess.run(args, input=json.dumps(payload, ensure_ascii=False).encode(),
                           capture_output=True, timeout=360)
    if child.returncode or len(child.stdout) > 12 * 1024 * 1024 or child.stdout.count(FRAME) != 1:
        raise ValueError('cb_notes/native')
    result = json.loads(child.stdout.split(FRAME)[1])
    if result.get('model') != expected or result.get('native') != expected:
        raise ValueError('cb_notes/projection')
    ui = result.get('ui')
    if not isinstance(ui, dict) or ui.get('result') != 'PASS' or ui.get('profile_removed') is not True \
            or ui.get('installed_bytes_match') is not True or not isinstance(ui.get('stages'), list) \
            or len(ui['stages']) != 2:
        raise ValueError('cb_notes/native')
    count = len(expected['reviews' if variant else 'updated'])
    for stage, mode in zip(ui['stages'], ('live', 'reopen')):
        validate_stage(stage, mode, count, thoughts=variant == 'thoughts')
    return {'live_requests': ui['stages'][0]['requests'], 'offline_requests': ui['stages'][1]['requests'],
            'rows': count, 'profile_removed': True, 'installed_bytes_match': True}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--native-command', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.native_command and not args.saved_session:
        parser.error('native UI requires --saved-session')
    report = dict(result='OFFLINE_ONLY', checked_at=datetime.now(timezone.utc).isoformat(),
                  account_data_posts=0, authentication_posts=0, private_values_in_report=False)
    saved = credentials = None
    samples = []
    try:
        if args.saved_session:
            saved = SessionStore().load()
            credentials = NativeSessionStore().load(saved['vid'])
            probe = CbNotesProbe()
            ids = cb_ids(probe.shelf(credentials))
            probe.ids = set(ids)
            now = int(time.time())
            for identity in ids:
                raw = probe.read('marks', identity, credentials)
                projected = project(raw, identity, credentials['vid'], now)
                samples.append((identity, raw, projected))
            identity, raw_marks, marks = max(samples, key=lambda row: len(row[2]['updated']))
            raw_thoughts = probe.read('thoughts', identity, credentials)
            thoughts = complete(raw_thoughts, identity, credentials['vid'], now)
            report.update(books=len(ids), mark_rows=sum(len(row[2]['updated']) for row in samples),
                          selected_mark_rows=len(marks['updated']), selected_thought_rows=len(thoughts['reviews']),
                          python_marks_gets=len(ids), python_thought_gets=1)
            if args.native_command:
                runs = []
                for variant, source, expected in ((None, raw_marks, marks), ('thoughts', raw_thoughts, thoughts)):
                    for width, height, dpi in ((600, 800, 167), (1264, 1680, 300)):
                        run = native_ui(args.native_command, source, identity, credentials['vid'], credentials,
                                        now, variant, expected, width, height, dpi)
                        runs.append(dict(variant=variant or 'marks', width=width, height=height, **run))
                report['native_ui'] = runs
            if cb_ids(probe.shelf(credentials)) != ids:
                raise ValueError('cb_notes/shelf_changed')
            report.update(result='CB_PERSONAL_NOTES_READ_VERIFIED', shelf_identity_unchanged=True)
    except Exception:
        report.update(result='UNVERIFIED', reason='cb_personal_notes_verification_failed')
    finally:
        samples.clear()
        if credentials:
            credentials.clear()
        if saved:
            saved.clear()
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report['result'] in ('OFFLINE_ONLY', 'CB_PERSONAL_NOTES_READ_VERIFIED') else 1


if __name__ == '__main__':
    raise SystemExit(main())
