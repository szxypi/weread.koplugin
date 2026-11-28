#!/usr/bin/env python3
"""One isolated EPUB status experiment; offline by default and no replay."""
import argparse
import json
from pathlib import Path
import resource
import tempfile
from urllib.parse import urlencode

from cloud_group_contract import project
from cloud_group_fixture import Journal, binding
from cloud_group_nonempty_workflow import strip_fixture
from cloud_group_trial import _cross_channel
from native_direct_time_trial_store import Intent
from personal_upload_trial import hash_value
from reading_status_fixture_trial import Trial, request
from secure_native_session import NativeSessionStore, project_lock
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from synthetic_format_trial import TargetReceipt
from verify_cloud_group_trial import FULL_SHELF, no_other_pending
from verify_eink_login import BASE, NativeProbe
from verify_personal_upload_trial import Probe as UploadProbe
from verify_shelf_flags import WebFlagsProbe
from verify_synthetic_epub_upload import read_source, run as upload


def backend(name):
    return MacKeychain(service='org.codex.weread.reading-status-fixture-' + name + '-v1', account=ACCOUNT)


def lock(name):
    path = Path(tempfile.gettempdir()) / ('codex-reading-status-fixture-' + name + '-' + ACCOUNT + '.lock')
    return lambda: project_lock(path)


def stores():
    return (Journal(backend=backend('upload'), lock=lock('upload')),
            TargetReceipt('epub', backend=backend('target'), scope='group-fixture'),
            Intent(backend=backend('mark'), lock=lock('mark')),
            Intent(backend=backend('restore'), lock=lock('restore')))


class ScopedNative(NativeProbe):
    def __init__(self, grant, current, pending, upload_journal, receipt, intents, opener=None):
        super().__init__(opener)
        self.grant, self.current, self.pending = grant, current, pending
        self.upload, self.receipt, self.intents = upload_journal, receipt, intents
        self.attempts = {'mark': 0, 'restore': 0}

    def request(self, *args, **kwargs):
        raise ValueError('reading_fixture/scope')

    def shelf(self):
        if self.current() is not True:
            raise ValueError('reading_fixture/owner')
        return super().request('shelf', FULL_SHELF, credentials=self.grant)

    def progress(self, target):
        state, _ = binding(self.upload, self.receipt.backend)
        if self.current() is not True or state['target'] != target:
            raise ValueError('reading_fixture/target')
        return super().request('progress', BASE + '/book/getProgress?' + urlencode({'bookId': target}),
                               credentials=self.grant)

    def send(self, kind, plan):
        if kind not in self.intents or self.current() is not True or self.pending() is not True:
            raise ValueError('reading_fixture/scope')
        state, _ = binding(self.upload, self.receipt.backend)
        expected = dict(owner=self.grant['vid'], target=state['target'], upload_attempt=state['attempt'],
                        upload_plan_hash=hash_value(state['plan']), grant_hash=hash_value(self.grant))
        if (state['plan']['owner'] != expected['owner'] or state['plan']['grant_sha256'] != expected['grant_hash']
                or plan.get('selection') != expected or plan.get('record') != {'kind': kind}
                or plan.get('body') != request(state['target'], kind == 'restore')
                or self.attempts[kind] or self.intents[kind].read()[0] is not None):
            raise ValueError('reading_fixture/scope')
        if kind == 'restore' and (self.intents['mark'].read()[0] is None or self.attempts['mark'] != 1):
            raise ValueError('reading_fixture/scope')
        # A crash or uncertain response leaves this permanent claim in Keychain.
        self.intents[kind].claim(plan)
        self.attempts[kind] += 1
        return super().request('status', BASE + '/book/markstatus', body=plan['body'], credentials=self.grant)


def run(saved, native_store, web, upload_journal, receipt, intents, *, apply=False):
    report = dict(result='UNVERIFIED', phase='preflight', fixture_only=True, existing_book_writes=0,
                  status_posts=0, fixture_cleanup_posts=0, no_automatic_replay=True)
    grant = native_store.load(saved['vid'])
    def current():
        return SessionStore().load() == saved and native_store.load(saved['vid']) == grant
    def pending():
        return no_other_pending()
    native = ScopedNative(grant, current, pending, upload_journal, receipt, intents)
    def shelves():
        web.verify_account()
        return {'native': native.shelf(), 'web': web.request('shelf', 'https://weread.qq.com/web/shelf/sync')}
    try:
        if (upload_journal.read()[0] is not None or receipt.backend.load() is not None
                or any(intent.read()[0] is not None for intent in intents.values()) or pending() is not True):
            raise ValueError('reading_fixture/consumed')
        first = shelves()
        original = {name: project(value) for name, value in first.items()}
        if not _cross_channel(original['native'], original['web']):
            raise ValueError('reading_fixture/channels')
        if {name: project(value) for name, value in shelves().items()} != original:
            raise ValueError('reading_fixture/unstable')
        probe = UploadProbe(upload_journal, lambda value: current() and value == grant)
        trial_report = None
        def gate(_journal, _token, _plan, target):
            nonlocal trial_report
            def read(identity):
                pair = shelves()
                return dict(native_shelf=pair['native'], web_shelf=pair['web'], native_progress=native.progress(identity))
            trial = Trial(upload_journal, receipt, grant, current, pending, original, read, native.send)
            trial_report = trial.run(target)
            report['status_posts'] = sum(native.attempts.values())
            report['trial'] = trial_report
            if trial_report['result'] != 'PASS' and trial_report['status_posts'] != 0:
                return False
            pair = shelves()
            return (current() and pending()
                    and all(strip_fixture(pair[name], target) == original[name] for name in ('native', 'web')))
        result = upload(probe, upload_journal, grant, lambda value: current() and value == grant,
                        lambda target: read_source(saved, target), apply=apply,
                        notify_receipt=receipt.record, cleanup_gate=gate)
        report.update(phase=result['phase'], upload_result=result['result'],
                      fixture_cleanup_posts=result['cleanup_posts'], fixture_notify_posts=result['notify_posts'],
                      fixture_source_verified=result['source_verified'])
        if not apply and result['result'] == 'READ_ONLY_PREVIEW':
            report['result'] = 'READ_ONLY_PREVIEW'
        elif result['phase'] == 'restored' and {k: project(v) for k, v in shelves().items()} == original:
            report['full_shelf_restored'] = True
            report['result'] = 'PASS' if trial_report and trial_report['result'] == 'PASS' else 'FIXTURE_REMOVED_NO_STATUS_TEST'
    except Exception:
        report['reason'] = 'reading_fixture/unavailable'
    finally:
        report['status_posts'] = sum(native.attempts.values())
        grant.clear()
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--preview', action='store_true')
    mode.add_argument('--apply', action='store_true')
    args = parser.parse_args(argv)
    if args.saved_session != bool(args.preview or args.apply):
        parser.error('saved session requires one explicit mode')
    if not args.saved_session:
        print(json.dumps({'result': 'OFFLINE_ONLY', 'status_posts': 0}))
        return 0
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    saved = web = None
    try:
        saved = SessionStore().load()
        web = WebFlagsProbe()
        web.vid = saved['vid']
        for key, value in saved['cookies'].items():
            web.set_cookie(key, value)
        web.verify_account()
        journal, receipt, mark, restore = stores()
        report = run(saved, NativeSessionStore(), web, journal, receipt,
                     {'mark': mark, 'restore': restore}, apply=args.apply)
    except Exception:
        report = {'result': 'UNVERIFIED', 'reason': 'reading_fixture/unavailable'}
    finally:
        if web:
            web.close()
        if saved:
            saved.clear()
    print(json.dumps(report, indent=2))
    return 0 if report['result'] in ('OFFLINE_ONLY', 'READ_ONLY_PREVIEW', 'PASS', 'FIXTURE_REMOVED_NO_STATUS_TEST') else 1


if __name__ == '__main__':
    raise SystemExit(main())
