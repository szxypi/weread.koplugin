#!/usr/bin/env python3
"""Inspect or recover the one isolated fixture after an uncertain mark."""
import argparse
import json
import resource
from urllib.parse import urlencode

from cloud_group_contract import project
from cloud_group_fixture import binding
from cloud_group_trial import _cross_channel
from personal_upload_trial import hash_value
from reading_status_fixture_trial import progress, request, target_row
from reading_status_recovery import reconstruct, run
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from synthetic_epub_trial import check
from verify_cloud_group_trial import FULL_SHELF, no_other_pending
from verify_eink_login import BASE, NativeProbe
from verify_reading_status_fixture import stores
from verify_shelf_flags import WebFlagsProbe


class RecoveryProbe(NativeProbe):
    def __init__(self, grant, current, pending, upload, receipt, mark, restore, opener=None):
        super().__init__(opener)
        self.grant, self.current, self.pending = grant, current, pending
        self.upload, self.receipt, self.mark, self.restore = upload, receipt, mark, restore
        self.attempts = 0

    def request(self, *args, **kwargs):
        raise ValueError('reading_recovery/scope')

    def bound(self):
        state, _ = binding(self.upload, self.receipt.backend)
        if (self.current() is not True or self.pending() is not True
                or state['plan']['owner'] != self.grant['vid']
                or state['plan']['grant_sha256'] != hash_value(self.grant)):
            raise ValueError('reading_recovery/owner')
        return state

    def shelf(self):
        self.bound()
        return super().request('shelf', FULL_SHELF, credentials=self.grant)

    def progress(self, target):
        if self.bound()['target'] != target:
            raise ValueError('reading_recovery/target')
        return super().request('progress', BASE + '/book/getProgress?' + urlencode({'bookId': target}),
                               credentials=self.grant)

    def send(self, state, plan):
        if self.bound() != state or self.attempts or self.restore.read()[0] is not None:
            raise ValueError('reading_recovery/scope')
        mark, _ = self.mark.read()
        expected = dict(owner=state['plan']['owner'], target=state['target'], upload_attempt=state['attempt'],
                        upload_plan_hash=hash_value(state['plan']), grant_hash=state['plan']['grant_sha256'])
        if (not mark or mark['phase'] != 'claimed' or mark['plan']['selection'] != expected
                or mark['plan']['record'] != {'kind': 'mark'}
                or mark['plan']['body'] != request(state['target'], False)
                or plan['selection'] != expected or plan['record'] != {'kind': 'restore'}
                or plan['body'] != request(state['target'], True)):
            raise ValueError('reading_recovery/scope')
        self.restore.claim(plan)
        self.attempts += 1
        return super().request('status_restore', BASE + '/book/markstatus', body=plan['body'], credentials=self.grant)


def execute(saved, native_store, web, upload, receipt, mark, restore, *, apply=False):
    grant = native_store.load(saved['vid'])
    def current():
        return SessionStore().load() == saved and native_store.load(saved['vid']) == grant
    probe = RecoveryProbe(grant, current, no_other_pending, upload, receipt, mark, restore)
    def observe(state):
        if probe.bound() != state:
            raise ValueError('reading_recovery/binding')
        web.verify_account()
        native = probe.shelf()
        web_shelf = web.request('shelf', 'https://weread.qq.com/web/shelf/sync')
        check(state['plan'], grant, native, state['target'], True)
        if not _cross_channel(project(native), project(web_shelf)):
            raise ValueError('reading_recovery/channels')
        return dict(native=target_row(native, state['target']), web=target_row(web_shelf, state['target']),
                    progress=progress(probe.progress(state['target']), state['target']))
    try:
        if apply:
            report = run(mark, restore, probe.bound, current, no_other_pending, observe, probe.send)
        else:
            state = probe.bound()
            record, _ = mark.read()
            if not record or record['phase'] != 'claimed' or restore.read()[0] is not None:
                raise ValueError('reading_recovery/scope')
            one, two = observe(state), observe(state)
            if one != two:
                raise ValueError('reading_recovery/unstable')
            reconstruct(one, record['plan']['baseline']['snapshot_hash'])
            report = dict(result='READ_ONLY_PREVIEW', fixture_bound=True, baseline_verified=True, restore_posts=0)
    except Exception:
        report = dict(result='UNVERIFIED', restore_posts=0)
    finally:
        report['restore_posts'] = probe.attempts
        grant.clear()
    report.update(fixture_only=True, existing_book_writes=0, no_automatic_replay=True)
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--inspect', action='store_true')
    modes.add_argument('--apply', action='store_true')
    args = parser.parse_args(argv)
    if args.saved_session != bool(args.inspect or args.apply):
        parser.error('saved session requires one explicit mode')
    if not args.saved_session:
        print(json.dumps({'result': 'OFFLINE_ONLY', 'restore_posts': 0}))
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
        report = execute(saved, NativeSessionStore(), web, *stores(), apply=args.apply)
    except Exception:
        report = {'result': 'UNVERIFIED', 'restore_posts': 0}
    finally:
        if web:
            web.close()
        if saved:
            saved.clear()
    print(json.dumps(report, indent=2))
    return 0 if report['result'] in ('READ_ONLY_PREVIEW', 'RESTORED', 'RESTORED_ACK_UNKNOWN') else 1


if __name__ == '__main__':
    raise SystemExit(main())
