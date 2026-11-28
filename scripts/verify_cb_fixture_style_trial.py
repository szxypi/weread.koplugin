#!/usr/bin/env python3
"""Verify imported-book highlight styles on one isolated self-authored book."""
import argparse
import json
from pathlib import Path
import resource
import tempfile

from annotation_experiment_model import digest
from cb_fixture_style_trial import Intent, execute, prepare
from highlight_trial_model import observe
from secure_native_session import NativeSessionStore, project_lock
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from synthetic_epub_trial import Journal
from verify_cb_fixture_highlight_trial import ScopedNative as BaseNative, run as run_fixture
from verify_eink_login import BASE, NativeProbe

UPLOAD_SERVICE = 'org.codex.weread.cb-fixture-style-upload-v1'


def stores():
    backend = MacKeychain(service=UPLOAD_SERVICE, account=ACCOUNT)
    path = Path(tempfile.gettempdir()) / ('codex-cb-fixture-style-upload-' + ACCOUNT + '.lock')
    return Journal(backend=backend, lock=lambda: project_lock(path)), Intent()


class ScopedNative(BaseNative):
    def __init__(self, book, grant, authority, intent, *, opener=None):
        super().__init__(book, grant, authority, intent, opener=opener, max_gets=80)

    def request(self, stage, url, body=None, credentials=None, timeout=15):
        if body is None:
            return super().request(stage, url, body, credentials, timeout)
        if not self.authority() or digest(credentials) != self.grant_hash:
            raise ValueError('cb_style/ownership')
        state, receipt = self.intent.read()
        phases = ('create_pending', 'straight_pending', 'wave_pending', 'delete_pending')
        if (self.pending is None or state is None or receipt != self.pending[1] or stage != self.pending[0]
                or self.posts >= len(phases) or stage != phases[self.posts] or not self.intent.owns(receipt, stage)
                or state['plan']['book_sha256'] != digest(self.book)
                or state['plan']['owner_sha256'] != digest(credentials['vid'])):
            raise ValueError('cb_style/write_scope')
        if stage == 'create_pending':
            valid = url == BASE + '/book/addBookmark' and body == self.body and digest(body) == state['plan']['request_sha256']
        elif stage == 'delete_pending':
            valid = url == BASE + '/book/removeBookmark' and body == {'bookmarkIds': [state['target']['id']]}
        else:
            style = 0 if stage == 'straight_pending' else 2
            valid = url == BASE + '/book/updateBookmark' and body == dict(bookmarkId=state['target']['id'], style=style, colorStyle=0)
        if not valid:
            raise ValueError('cb_style/write_scope')
        self.posts += 1
        result = NativeProbe.request(self, stage, url, body, credentials, timeout)
        if not self.authority(): raise ValueError('cb_style/ownership')
        return result

    def send(self, stage, body, receipt, grant):
        if self.pending is not None: raise ValueError('cb_style/write_scope')
        self.pending = (stage, receipt)
        try:
            path = {'create_pending': '/book/addBookmark', 'straight_pending': '/book/updateBookmark',
                    'wave_pending': '/book/updateBookmark', 'delete_pending': '/book/removeBookmark'}[stage]
            return self.request(stage, BASE + path, body, grant)
        finally:
            self.pending = None


def run(saved, session, native_store, grant, journal, intent, *, apply=False, **dependencies):
    def final_check(baseline, current, body):
        return observe(baseline, current, body, deleted=True) is None
    dependencies.setdefault('native_factory', ScopedNative)
    return run_fixture(saved, session, native_store, grant, journal, intent, apply=apply, prepare_fn=prepare,
        execute_fn=execute, final_check=final_check, expected_posts=4,
        result_label='CB_FIXTURE_STYLE_VERIFIED', **dependencies)


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
    print(json.dumps(report, ensure_ascii=False)); return int(report['result'] not in ('READ_ONLY_PREVIEW', 'CB_FIXTURE_STYLE_VERIFIED'))


if __name__ == '__main__': raise SystemExit(main())
