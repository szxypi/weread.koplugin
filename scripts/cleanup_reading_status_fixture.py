#!/usr/bin/env python3
"""Remove only the isolated status fixture after independent recovery checks."""
import argparse
import json
import resource

from cloud_group_contract import project
from cloud_group_fixture import binding
from cloud_group_trial import _cross_channel
from native_direct_time_trial_store import Intent
from reading_status_fixture_cleanup import run
from reading_status_fixture_trial import progress, target_row
from resolve_reading_status_fixture import RecoveryProbe
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from synthetic_epub_trial import check
from verify_cloud_group_trial import no_other_pending
from verify_personal_upload_trial import Probe as UploadProbe
from verify_reading_status_fixture import backend, lock, stores
from verify_shelf_flags import WebFlagsProbe


def execute(saved, native_store, web, upload, receipt, mark, restore, cleanup, *, apply=False):
    grant = native_store.load(saved['vid'])
    def current():
        return SessionStore().load() == saved and native_store.load(saved['vid']) == grant
    probe = RecoveryProbe(grant, current, no_other_pending, upload, receipt, mark, restore)
    uploader = UploadProbe(upload, lambda value: current() and value == grant)
    def bound():
        state, token = binding(upload, receipt.backend)
        if probe.bound() != state:
            raise ValueError('reading_cleanup/binding')
        return state, token
    def observe(state):
        if bound()[0] != state:
            raise ValueError('reading_cleanup/binding')
        web.verify_account()
        native = probe.shelf()
        web_shelf = web.request('shelf', 'https://weread.qq.com/web/shelf/sync')
        check(state['plan'], grant, native, state['target'], True)
        if not _cross_channel(project(native), project(web_shelf)):
            raise ValueError('reading_cleanup/channels')
        return dict(native=target_row(native, state['target']), web=target_row(web_shelf, state['target']),
                    progress=progress(probe.progress(state['target']), state['target']))
    def after(state):
        if current() is not True or no_other_pending() is not True:
            return False
        web.verify_account()
        native = uploader.shelf(grant)
        web_shelf = web.request('shelf', 'https://weread.qq.com/web/shelf/sync')
        check(state['plan'], grant, native, state['target'], False)
        return _cross_channel(project(native), project(web_shelf))
    try:
        report = run(upload, mark, restore, cleanup, bound, current, no_other_pending, observe,
                     lambda token: uploader.cleanup(grant, token), after, apply=apply)
    finally:
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
        print(json.dumps({'result': 'OFFLINE_ONLY', 'cleanup_posts': 0}))
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
        cleanup = Intent(backend=backend('cleanup'), lock=lock('cleanup'))
        report = execute(saved, NativeSessionStore(), web, *stores(), cleanup, apply=args.apply)
    except Exception:
        report = {'result': 'UNVERIFIED', 'cleanup_posts': 0}
    finally:
        if web:
            web.close()
        if saved:
            saved.clear()
    print(json.dumps(report, indent=2))
    return 0 if report['result'] in ('READ_ONLY_PREVIEW', 'CLEANED', 'CLEANED_ACK_UNKNOWN') else 1


if __name__ == '__main__':
    raise SystemExit(main())
