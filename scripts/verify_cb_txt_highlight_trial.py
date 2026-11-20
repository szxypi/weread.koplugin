#!/usr/bin/env python3
"""One isolated TXT highlight create/remove experiment; offline by default.

The fixture has its own upload journal, import receipt and two-write intent.
Unexpected effects retain the fixture and reservation; no write is replayed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import resource
import tempfile

from cb_txt_highlight_trial import BODY,TEXT,Intent,execute as highlight_execute,prepare as highlight_prepare
from personal_upload_trial import Journal as BaseJournal,check,hash_value,prepare,validate
from secure_native_session import NativeSessionStore,project_lock
from secure_shelf_experiment import canonical
from secure_weread_session import ACCOUNT,MacKeychain,SessionStore
from verify_cb_fixture_highlight_trial import run as run_highlight
from verify_cb_fixture_position_trial import owned
from verify_cb_txt_fixture import Receipt
from verify_synthetic_epub_upload import run as upload_run


def validate_plan(plan):
    validate(plan)
    if plan['body_sha256']!=hashlib.sha256(BODY).hexdigest():raise ValueError('cb_txt_highlight/fixture')
    return plan


def prepare_plan(credentials,shelf,name):
    return validate_plan(prepare(credentials,shelf,name,BODY))


def check_plan(plan,credentials,shelf,target=None,expected=False):
    return check(plan,credentials,shelf,target,expected,validator=validate_plan)


def stores():
    def backend(part):return MacKeychain(service='org.codex.weread.cb-txt-highlight-'+part+'-v1',account=ACCOUNT)
    def lock(part):
        path=Path(tempfile.gettempdir())/('codex-cb-txt-highlight-'+part+'-'+ACCOUNT+'.lock')
        return lambda:project_lock(path)
    journal=BaseJournal(backend=backend('upload'),lock=lock('upload'),validator=validate_plan)
    return journal,Receipt(backend=backend('receipt')),Intent()


def fixture_authorized(journal,receipt,target,owner,grant,same_grant,target_receipt):
    if not owned(journal,receipt,target,owner,grant,same_grant):return False
    state,current=journal.read()
    if not state or current!=receipt:return False
    expected=canonical(dict(schema=1,owner=owner,attempt=state['attempt'],target=target,
                            plan_sha256=hash_value(state['plan'])))
    return target_receipt.backend.load()==expected


def run(saved,session,native,grant,journal,receipt,intent,*,apply=False,runner=run_highlight,uploader=upload_run):
    if receipt.backend.load() is not None:
        return dict(result='UNVERIFIED',phase='preflight',annotation_posts=0,authentication_posts=0)
    def upload(probe,journal_arg,grant_arg,grant_check,source,*,apply,cleanup_gate):
        if journal_arg is not journal or grant_arg!=grant or receipt.backend.load() is not None:
            raise ValueError('cb_txt_highlight/authority')
        return uploader(probe,journal,grant,grant_check,source,apply=apply,cleanup_gate=cleanup_gate,
                        fixture_builder=lambda:BODY,prepare_plan=prepare_plan,check_plan=check_plan,
                        fixture_extension='txt',readback_tries=7,notify_receipt=receipt.record)
    def authority(journal_arg,claim,target,owner,grant_arg,same_grant):
        return fixture_authorized(journal_arg,claim,target,owner,grant_arg,same_grant,receipt)
    return runner(saved,session,native,grant,journal,intent,apply=apply,uploader=upload,
                  prepare_fn=highlight_prepare,execute_fn=highlight_execute,source_format='web_txt',source_marker=TEXT,
                  upload_success='TXT_IMPORT_AND_SOURCE_VERIFIED',fixture_authorized=authority,
                  result_label='CB_TXT_HIGHLIGHT_VERIFIED')


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true');parser.add_argument('--apply',action='store_true')
    args=parser.parse_args(argv)
    if args.apply and not args.saved_session:parser.error('apply requires saved session')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY',annotation_posts=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=None
    try:
        session=SessionStore();saved=session.load();native=NativeSessionStore();grant=native.load(saved['vid'])
        report=run(saved,session,native,grant,*stores(),apply=args.apply)
    except Exception:
        report=dict(result='UNVERIFIED',phase='setup',annotation_posts=0)
    finally:
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(report));return 0 if report['result'] in ('READ_ONLY_PREVIEW','CB_TXT_HIGHLIGHT_VERIFIED') else 1


if __name__=='__main__':raise SystemExit(main())
