#!/usr/bin/env python3
"""Fresh native TXT bookmark roundtrip with complete Web snapshot comparison."""
import argparse
import json
from pathlib import Path
import resource
import tempfile

import cb_txt_padded_bookmark_trial as trial
from personal_upload_trial import Journal
from secure_native_session import NativeSessionStore,project_lock
from secure_weread_session import ACCOUNT,MacKeychain,SessionStore
from verify_cb_txt_fixture import Receipt
import verify_cb_txt_padded_bookmark_native as fixture
import verify_cb_txt_bookmark_cross_channel as previous
from verify_cb_txt_official_bookmark_probe import fixture_target


def stores():
    def backend(part):return MacKeychain(service='org.codex.weread.cb-txt-bookmark-cross-channel-strict-'+part+'-v1',account=ACCOUNT)
    def lock(part):
        path=Path(tempfile.gettempdir())/('codex-cb-txt-bookmark-cross-channel-strict-'+part+'-'+ACCOUNT+'.lock')
        return lambda:project_lock(path)
    return (Journal(backend=backend('upload'),lock=lock('upload'),validator=fixture.validate_plan),
            Receipt(backend=backend('receipt')),trial.Intent(backend=backend('intent'),lock=lock('intent')))


def run(saved,session,native,grant,journal,receipt,intent,command,*,apply=False,prior=None,runner=previous.run):
    old_journal,old_receipt,old_intent=prior if prior is not None else previous.stores()
    owner=saved['vid'];target=fixture_target(old_journal,old_receipt,old_intent,owner)
    state,claim=old_journal.read();raw=old_receipt.backend.load()
    result=runner(saved,session,native,grant,journal,receipt,intent,command,apply=apply)
    try:
        unchanged=(fixture_target(old_journal,old_receipt,old_intent,owner)==target
                   and old_journal.read()==(state,claim) and old_receipt.backend.load()==raw)
    except Exception:unchanged=False
    result['prior_scope_unchanged']=unchanged
    if not unchanged:
        result['result']='CB_TXT_BOOKMARK_STRICT_CROSS_CHANNEL_UNVERIFIED'
        return result
    if result.get('result')=='CB_TXT_BOOKMARK_CROSS_CHANNEL_VERIFIED':
        result['result']='CB_TXT_BOOKMARK_STRICT_CROSS_CHANNEL_VERIFIED'
        result['complete_web_snapshot_stable']=True
    return result


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--apply',action='store_true');parser.add_argument('--runner',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    if args.apply and not args.saved_session or args.saved_session and not args.runner or args.runner and not args.saved_session:
        parser.error('saved session and runner required')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY',native_writes_allocated=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=None
    try:
        session=SessionStore();saved=session.load();native=NativeSessionStore();grant=native.load(saved['vid'])
        report=run(saved,session,native,grant,*stores(),args.runner,apply=args.apply)
    except Exception:report=dict(result='UNVERIFIED',phase='setup',native_writes_allocated=None)
    finally:
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(report));return int(report.get('result') not in ('READ_ONLY_PREVIEW','CB_TXT_BOOKMARK_STRICT_CROSS_CHANNEL_VERIFIED'))


if __name__=='__main__':raise SystemExit(main())
