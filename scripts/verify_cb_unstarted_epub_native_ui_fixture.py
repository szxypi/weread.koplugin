#!/usr/bin/env python3
"""Verify native first-sync UI after time on a fresh self-authored EPUB."""
import argparse
import json
from pathlib import Path
import resource
import tempfile

from cb_fixture_web_time_evidence import Evidence
from cb_fixture_web_time_intent import Intent
from secure_native_session import NativeSessionStore, project_lock
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from synthetic_epub_trial import Journal
from verify_cb_txt_fixture import Receipt
from verify_cb_unstarted_native_ui_fixture import execute
from verify_cb_initial_fixture_ui_trial import ui_command


def stores():
    def backend(name): return MacKeychain(service='org.codex.weread.cb-unstarted-epub-native-ui-' + name + '-v1', account=ACCOUNT)
    def lock(name):
        path = Path(tempfile.gettempdir()) / ('codex-cb-unstarted-epub-native-ui-' + name + '-' + ACCOUNT + '.lock')
        return lambda: project_lock(path)
    return (Journal(backend=backend('upload'), lock=lock('upload')), Receipt(backend=backend('receipt')),
            Intent(backend=backend('time'), lock=lock('time')), Evidence(backend=backend('time-baseline'), lock=lock('time-baseline')),
            Intent(backend=backend('position'), lock=lock('position')),
            Evidence(backend=backend('position-baseline'), lock=lock('position-baseline')))


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true'); parser.add_argument('--apply',action='store_true')
    args=parser.parse_args(argv)
    if args.apply and not args.saved_session: parser.error('apply requires saved session')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY',account_data_writes_known=0))); return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0)); saved=grant=None
    try:
        session=SessionStore(); saved=session.load(); native=NativeSessionStore(); grant=native.load(saved['vid'])
        result=execute(saved,session,native,grant,*stores(),ui_command(),apply=args.apply,fixture='epub')
    except Exception:
        result=dict(result='UNVERIFIED',phase='unknown' if args.apply else 'preflight',
                    account_data_writes_known=None if args.apply else 0,position_write_uncertain=args.apply,
                    authentication_posts=0,fixture_only=True,private_data_in_report=False)
    finally:
        if saved: saved.clear()
        if grant: grant.clear()
    print(json.dumps(result)); return int(result['result'] not in ('READ_ONLY_PREVIEW','UNSTARTED_TIME_NATIVE_UI_VERIFIED'))


if __name__=='__main__': raise SystemExit(main())
