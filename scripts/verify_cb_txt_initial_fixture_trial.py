#!/usr/bin/env python3
"""Isolated first-position trial for one new self-authored TXT import.

Offline by default. Real execution has its own durable upload, import receipt
and position budgets; uncertain outcomes retain the fixture and never replay.
This observes the server protocol only; it does not enable plugin writes.
"""
import argparse
import json
from pathlib import Path
import resource
import tempfile

from cb_initial_fixture_intent import Intent
from cb_txt_initial_fixture_plan import plan
from personal_upload_trial import hash_value
from secure_native_session import NativeSessionStore, project_lock
from secure_shelf_experiment import canonical
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from verify_cb_initial_fixture_trial import run
from verify_cb_txt_fixture import BODY, MARKER, Journal, Receipt, check_plan, prepare_plan
from verify_synthetic_epub_upload import run as upload_run


def stores():
    def backend(suffix):
        return MacKeychain(service='org.codex.weread.cb-txt-first-' + suffix + '-v1', account=ACCOUNT)
    def lock(suffix):
        path = Path(tempfile.gettempdir()) / ('codex-cb-txt-first-' + suffix + '-' + ACCOUNT + '.lock')
        return lambda: project_lock(path)
    return (Journal(backend=backend('upload'), lock=lock('upload')),
            Receipt(backend=backend('receipt')),
            Intent(backend=backend('position'), lock=lock('position')))


def execute(saved, session, native, grant, journal, receipt, intent, *, apply=False,
            trial=run, upload=upload_run):
    if receipt.backend.load() is not None:
        return dict(result='UNVERIFIED', phase='preflight', account_data_writes_known=0,
                    authentication_posts=0, fixture_only=True)

    def uploader(probe, journal_arg, grant_arg, grant_check, source, *, apply, cleanup_gate):
        if journal_arg is not journal or grant_arg != grant or receipt.backend.load() is not None:
            raise ValueError('cb_txt_initial/authority')
        return upload(probe, journal, grant, grant_check, source, apply=apply, cleanup_gate=cleanup_gate,
                      fixture_builder=lambda: BODY, prepare_plan=prepare_plan, check_plan=check_plan,
                      fixture_extension='txt', readback_tries=7, notify_receipt=receipt.record)

    def fixture_authorized(upload, claimed_receipt, target, owner):
        state, current = upload.read()
        if (not state or current != claimed_receipt or state.get('phase') != 'imported'
                or state.get('target') != target or state['plan'].get('owner') != owner):
            return False
        expected = canonical(dict(schema=1, owner=owner, attempt=state['attempt'], target=target,
                                  plan_sha256=hash_value(state['plan'])))
        return receipt.backend.load() == expected

    result = trial(saved, session, native, grant, journal, intent, apply=apply, uploader=uploader,
                   source_format='web_txt', source_marker=MARKER, position_planner=plan,
                   upload_success='TXT_IMPORT_AND_SOURCE_VERIFIED', fixture_authorized=fixture_authorized)
    if result.get('result') == 'CB_INITIAL_FIXTURE_VERIFIED':
        result['result'] = 'CB_TXT_INITIAL_FIXTURE_VERIFIED'
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args(argv)
    if args.apply and not args.saved_session: parser.error('apply requires saved session')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY', account_data_writes_known=0))); return 0
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0)); saved = grant = None
    try:
        session = SessionStore(); saved = session.load()
        native = NativeSessionStore(); grant = native.load(saved['vid'])
        result = execute(saved, session, native, grant, *stores(), apply=args.apply)
    except Exception:
        result = dict(result='UNVERIFIED', phase='unknown' if args.apply else 'preflight',
                      account_data_writes_known=None if args.apply else 0,
                      position_writes_uncertain=args.apply)
    finally:
        if saved: saved.clear()
        if grant: grant.clear()
    print(json.dumps(result))
    return int(result['result'] not in ('READ_ONLY_PREVIEW', 'CB_TXT_INITIAL_FIXTURE_VERIFIED'))


if __name__ == '__main__': raise SystemExit(main())
