#!/usr/bin/env python3
"""Bounded full style/color matrix on one fresh imported synthetic book."""
import argparse
import json
from pathlib import Path
import resource
import tempfile

from annotation_experiment_model import digest
from cb_fixture_style_color_trial import Intent, STEPS, dispatch_hash, execute, prepare
from highlight_trial_model import observe
from secure_native_session import NativeSessionStore, project_lock
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from synthetic_epub_trial import Journal
from verify_cb_fixture_highlight_trial import ScopedNative as BaseNative, run as run_fixture
from verify_eink_login import BASE, NativeProbe

UPLOAD_SERVICE = 'org.codex.weread.cb-fixture-style-color-upload-v2'


def stores():
    backend = MacKeychain(service=UPLOAD_SERVICE, account=ACCOUNT)
    path = Path(tempfile.gettempdir()) / ('codex-cb-fixture-matrix-upload-' + ACCOUNT + '.lock')
    return Journal(backend=backend, lock=lambda: project_lock(path)), Intent()


class ScopedNative(BaseNative):
    MAX_GETS = 640
    def __init__(self, book, grant, authority, intent, *, opener=None):
        super().__init__(book, grant, authority, intent, opener=opener, max_gets=self.MAX_GETS)

    def request(self, stage, url, body=None, credentials=None, timeout=15):
        if body is None: return super().request(stage, url, body, credentials, timeout)
        if not self.authority() or digest(credentials) != self.grant_hash: raise ValueError('cb_matrix/ownership')
        state, receipt = self.intent.read()
        if (self.pending is None or state is None or receipt != self.pending[1] or stage != self.pending[0]
                or type(stage) is not int or not 0 <= stage < len(STEPS) or stage != self.posts
                or state['step'] != stage or state['phase'] != 'claimed'
                or state['plan']['highlight']['book_sha256'] != digest(self.book)
                or state['plan']['highlight']['owner_sha256'] != digest(credentials['vid'])
                or state['dispatch_sha256'] != digest(body)
                or digest(body) != dispatch_hash(state['plan'], stage, state['target'])):
            raise ValueError('cb_matrix/write_scope')
        operation, _choice = STEPS[stage]
        path = {'create': '/book/addBookmark', 'color': '/book/updateBookmark',
                'style': '/book/updateBookmark', 'delete': '/book/removeBookmark'}[operation]
        if url != BASE + path or operation == 'create' and body.get('bookId') != self.book:
            raise ValueError('cb_matrix/write_scope')
        self.posts += 1
        result = NativeProbe.request(self, 'cb_matrix_' + str(stage), url, body, credentials, timeout)
        if not self.authority(): raise ValueError('cb_matrix/ownership')
        return result

    def send(self, stage, body, receipt, grant):
        if self.pending is not None or type(stage) is not int or not 0 <= stage < len(STEPS): raise ValueError('cb_matrix/write_scope')
        self.pending = (stage, receipt)
        try:
            operation, _choice = STEPS[stage]
            path = {'create': '/book/addBookmark', 'color': '/book/updateBookmark',
                    'style': '/book/updateBookmark', 'delete': '/book/removeBookmark'}[operation]
            return self.request(stage, BASE + path, body, grant)
        finally:
            self.pending = None


def run(saved, session, native_store, grant, journal, intent, *, apply=False, **dependencies):
    def final_check(baseline, current, body): return observe(baseline, current, body, deleted=True) is None
    dependencies.setdefault('native_factory', ScopedNative)
    report = run_fixture(saved, session, native_store, grant, journal, intent, apply=apply, prepare_fn=prepare,
                         execute_fn=execute, final_check=final_check, expected_posts=len(STEPS),
                         result_label='CB_FIXTURE_STYLE_COLOR_VERIFIED', **dependencies)
    if report['result'] == 'UNVERIFIED':
        try:
            value, _receipt = intent.read()
            if value: report.update(intent_step=value['step'], intent_phase=value['phase'])
        except Exception: report['intent_phase'] = 'unverified'
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true'); parser.add_argument('--apply', action='store_true')
    args = parser.parse_args(argv)
    if args.apply and not args.saved_session: parser.error('apply requires saved session')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY', annotation_posts=0))); return 0
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0)); saved = grant = None
    try:
        session = SessionStore(); saved = session.load(); native = NativeSessionStore(); grant = native.load(saved['vid'])
        report = run(saved, session, native, grant, *stores(), apply=args.apply)
    except Exception:
        report = dict(result='UNVERIFIED', phase='setup', annotation_posts=0)
    finally:
        if saved: saved.clear()
        if grant: grant.clear()
    print(json.dumps(report, ensure_ascii=False)); return int(report['result'] not in ('READ_ONLY_PREVIEW', 'CB_FIXTURE_STYLE_COLOR_VERIFIED'))


if __name__ == '__main__': raise SystemExit(main())
