#!/usr/bin/env python3
"""Native style/color verification on a fresh self-authored imported book.

Offline by default. The owned upload receipt and durable four-slot intent bind
one colored straight highlight, a colored style change, a color change and its
removal. Unknown effects retain the fixture and intent without retry.
"""
import argparse
from functools import partial
import json
from pathlib import Path
import resource
import tempfile

from annotation_experiment_model import digest
from cb_fixture_style_trial import Intent, prepare as prepare_style, validate_plan
from highlight_trial_model import observe
from secure_native_session import NativeSessionStore, project_lock
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from synthetic_epub_trial import Journal
from verify_cb_fixture_highlight_native import run as run_fixture
from verify_cb_fixture_style_native import run_ui

UPLOAD_SERVICE = 'org.codex.weread.cb-native-matrix-upload-v1'
INTENT_SERVICE = 'org.codex.weread.cb-native-matrix-intent-v1'


def stores():
    def backend(service): return MacKeychain(service=service, account=ACCOUNT)
    def lock(name):
        path = Path(tempfile.gettempdir()) / ('codex-cb-native-matrix-' + name + '-' + ACCOUNT + '.lock')
        return lambda: project_lock(path)
    return Journal(backend=backend(UPLOAD_SERVICE), lock=lock('upload')), Intent(backend=backend(INTENT_SERVICE), lock=lock('intent'))


def prepare(owner, book, attempt, sample, version, baseline):
    plan, body = prepare_style(owner, book, attempt, sample, version, baseline)
    body = dict(body, style=0, colorStyle=3)
    return validate_plan(dict(plan, request_sha256=digest(body))), body


def run(saved, session, native_store, grant, journal, intent, command, *, apply=False, **dependencies):
    def final_check(baseline, current, body): return observe(baseline, current, body, deleted=True) is None
    return run_fixture(saved, session, native_store, grant, journal, intent, command, apply=apply, prepare_fn=prepare,
                       native_writes=4, result_label='CB_NATIVE_MATRIX_VERIFIED', final_check=final_check,
                       ui_runner=partial(run_ui, matrix=True), **dependencies)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--apply', action='store_true'); parser.add_argument('--runner', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.apply and not args.saved_session or args.saved_session and not args.runner or args.runner and not args.saved_session:
        parser.error('saved session and runner required')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY', native_writes_allocated=0))); return 0
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0)); saved = grant = None
    try:
        session = SessionStore(); saved = session.load(); native = NativeSessionStore(); grant = native.load(saved['vid'])
        report = run(saved, session, native, grant, *stores(), args.runner, apply=args.apply)
    except Exception:
        report = dict(result='UNVERIFIED', phase='setup', native_writes_allocated=0)
    finally:
        if saved: saved.clear()
        if grant: grant.clear()
    print(json.dumps(report, ensure_ascii=False)); return int(report['result'] not in ('READ_ONLY_PREVIEW', 'CB_NATIVE_MATRIX_VERIFIED'))


if __name__ == '__main__': raise SystemExit(main())
