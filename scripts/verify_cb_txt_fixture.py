#!/usr/bin/env python3
"""One independent synthetic TXT import, scoped source read and removal.

Offline by default. The prior uncertain cloud group journals and their retained
fixture are read-only guards; no request can modify those records or their book.
The new upload uses separate durable one-shot and notification receipts.
"""
import argparse
import hashlib
import json
import resource
import tempfile
import time
from pathlib import Path

from cloud_group_binding import Binding
from cloud_group_fixture import Journal as GroupFixtureJournal, binding
from cloud_group_journal import Journal as OldJournal
from cloud_group_nonempty_binding import Binding as NonemptyBinding
from cloud_group_nonempty_inspect import inspect
from cloud_group_nonempty_journal import Journal as GroupJournal
from cloud_group_old_guard import Guard
from personal_upload_trial import Journal as BaseJournal, check, hash_value, prepare, validate
from secure_native_session import NativeSessionStore, project_lock
from secure_shelf_experiment import canonical
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from synthetic_format_trial import TargetReceipt
from verify_cb_reading import CbReadingError, CbReadingProbe
from verify_cb_metadata import CbMetadataError
from verify_cb_progress import cb_id
from verify_cloud_group_trial import FULL_SHELF
from verify_eink_login import NativeProbe
from verify_personal_upload_trial import Probe
from verify_shelf_flags import WebFlagsProbe
from verify_synthetic_epub_upload import run

MARKER = 'Unique synthetic TXT source paragraph for KOReader verification.'
BODY = (MARKER + '\nA second distinct line tests conversion of an uploaded plain text book.\n'
        + 'A third original line exercises the native reading source without personal content.\n').encode('utf-8')


def validate_plan(plan):
    validate(plan)
    if plan['body_sha256'] != hashlib.sha256(BODY).hexdigest(): raise ValueError('cb_txt/fixture')
    return plan


def prepare_plan(credentials, shelf, name):
    return validate_plan(prepare(credentials, shelf, name, BODY))


def check_plan(plan, credentials, shelf, target=None, expected=False):
    return check(plan, credentials, shelf, target, expected, validator=validate_plan)


class Journal(BaseJournal):
    def __init__(self, backend=None, lock=None):
        if backend is None:
            backend = MacKeychain(service='org.codex.weread.goal-cb-txt-fixture-v1', account=ACCOUNT)
            path = Path(tempfile.gettempdir()) / ('codex-cb-txt-fixture-' + ACCOUNT + '.lock')
            lock = lock or (lambda: project_lock(path))
        super().__init__(backend=backend, lock=lock, validator=validate_plan)


class Receipt:
    def __init__(self, backend=None):
        self.backend = backend or MacKeychain(service='org.codex.weread.goal-cb-txt-target-v1', account=ACCOUNT)

    def record(self, journal, receipt, plan, target):
        state, current = journal.read()
        if (not state or state['phase'] != 'notify_pending' or current != receipt or state['plan'] != plan
                or not cb_id(target) or self.backend.load() is not None):
            raise ValueError('cb_txt/receipt')
        raw = canonical(dict(schema=1, owner=plan['owner'], attempt=state['attempt'], target=target, plan_sha256=hash_value(plan)))
        self.backend.save(raw)
        if self.backend.load() != raw: raise ValueError('cb_txt/receipt')


def read_source(saved, target, summary, sleep=time.sleep):
    if not cb_id(target): raise ValueError('cb_txt/target')
    for attempt in range(5):
        web = CbReadingProbe()
        try:
            web.vid = saved['vid']; web.allowed = {target}
            for key, value in saved['cookies'].items(): web.set_cookie(key, value)
            web.verify_account(); sample = web.inspect(target); web.verify_account()
            checks = web.last_checks
            valid = (sample['book_id'] == target and sample['source_format'] in ('web_txt', 'web_xhtml')
                     and MARKER in sample['source'] and set(checks) == {'catalog_unchanged', 'versions_unchanged', 'position_unchanged'}
                     and all(value is True for value in checks.values()))
            if valid: summary.update(source_format=sample['source_format'], fixture_text_found=True, source_baseline_unchanged=True)
            return valid
        except (CbReadingError, CbMetadataError) as error:
            if str(error) not in ('cb_catalog_empty', 'cb_catalog_invalid') or attempt == 4: raise
        finally:
            web.samples.clear(); web.close()
        sleep(2 * (attempt + 1))
    return False


def guarded_previous(grant, current, native, web):
    def read_pair():
        web.verify_account()
        return dict(native=native.request('shelf_full', FULL_SHELF, credentials=grant),
                    web=web.request('shelf', 'https://weread.qq.com/web/shelf/sync'))
    Guard(OldJournal(), Binding(), grant, current, read_pair).check(False)
    fixture = GroupFixtureJournal(); target = TargetReceipt('epub', scope='group-fixture')
    result = inspect(GroupJournal(), lambda: binding(fixture, target.backend), grant, current, read_pair, NonemptyBinding())
    if not all(result[key] is expected for key, expected in (
            ('native_fixture_present', True), ('web_fixture_present', True),
            ('native_group_present', False), ('web_group_present', False))):
        raise ValueError('cb_txt/old_group_changed')
    return True


def execute(probe, journal, receipt, credentials, current, read_content, old_guard, *, apply=False, sleep=time.sleep, now=time.time):
    if receipt.backend.load() is not None or old_guard() is not True: raise ValueError('cb_txt/guard')
    def cleanup_gate(_journal, _receipt, _plan, target):
        old_journal = GroupJournal(); old_state, old_receipt = old_journal.read()
        if not old_state or target == old_state['target'] or old_guard() is not True: return False
        return old_journal.read() == (old_state, old_receipt)
    return run(probe, journal, credentials, current, read_content, apply=apply, sleep=sleep, now=now,
               fixture_builder=lambda: BODY, prepare_plan=prepare_plan, check_plan=check_plan,
               fixture_extension='txt', readback_tries=7, notify_receipt=receipt.record, cleanup_gate=cleanup_gate)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true'); parser.add_argument('--apply', action='store_true')
    args = parser.parse_args(argv)
    if args.apply and not args.saved_session: parser.error('--apply requires --saved-session')
    report = dict(result='OFFLINE_ONLY', account_data_writes=0, authentication_posts=0)
    saved = grant = web = None; summary = {}
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    try:
        if args.saved_session:
            session = SessionStore(); saved = session.load(); native_store = NativeSessionStore(); grant = native_store.load(saved['vid'])
            def current(value=None): return session.load() == saved and native_store.load(saved['vid']) == grant and (value is None or value == grant)
            web = WebFlagsProbe(); web.vid = saved['vid']
            for key, value in saved['cookies'].items(): web.set_cookie(key, value)
            native = NativeProbe(); web.verify_account()
            previous = lambda: guarded_previous(grant, current, native, web)
            journal, receipt = Journal(), Receipt()
            report = execute(Probe(journal, current), journal, receipt, grant, current,
                             lambda target: read_source(saved, target, summary), previous, apply=args.apply)
            report.update(summary); report['old_group_guard_passed_after'] = previous()
            report['account_data_writes'] = report['notify_posts'] + report['cleanup_posts']
    except Exception:
        report.update(result='UNVERIFIED', reason='cb_txt/guard_or_execution', authentication_posts=0)
        if args.apply:
            notified, cleaned = report.get('notify_posts'), report.get('cleanup_posts')
            report['account_data_writes'] = notified + cleaned if type(notified) is int and type(cleaned) is int else None
    finally:
        if web: web.close()
        if grant: grant.clear()
        if saved: saved.clear()
    print(json.dumps(report, ensure_ascii=False))
    return 0 if report['result'] in ('OFFLINE_ONLY','READ_ONLY_PREVIEW','TXT_IMPORT_AND_SOURCE_VERIFIED') else 1


if __name__ == '__main__': raise SystemExit(main())
