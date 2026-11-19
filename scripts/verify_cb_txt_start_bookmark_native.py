#!/usr/bin/env python3
"""Native TXT bookmark at the start of a short isolated synthetic book."""
import argparse
import hashlib
import json
from pathlib import Path
import resource
import tempfile

import cb_txt_start_bookmark_trial as trial
from personal_upload_trial import Journal,check,prepare,validate
from secure_native_session import NativeSessionStore,project_lock
from secure_weread_session import ACCOUNT,MacKeychain,SessionStore
from txt_coordinates import PlainSource
from verify_cb_fixture_bookmark_native import run as run_bookmark
from verify_cb_txt_fixture import Receipt
from verify_cb_txt_highlight_trial import fixture_authorized
from verify_synthetic_epub_upload import run as upload_run


def validate_plan(plan):
    validate(plan)
    if plan['body_sha256']!=hashlib.sha256(trial.BODY).hexdigest():raise ValueError('txt_bookmark/fixture')
    return plan


def prepare_plan(credentials,shelf,name):
    return validate_plan(prepare(credentials,shelf,name,trial.BODY))


def check_plan(plan,credentials,shelf,target=None,expected=False):
    return check(plan,credentials,shelf,target,expected,validator=validate_plan)


def stores():
    def backend(part):return MacKeychain(service='org.codex.weread.cb-txt-start-bookmark-'+part+'-v1',account=ACCOUNT)
    def lock(part):
        path=Path(tempfile.gettempdir())/('codex-cb-txt-start-bookmark-'+part+'-'+ACCOUNT+'.lock')
        return lambda:project_lock(path)
    return (Journal(backend=backend('upload'),lock=lock('upload'),validator=validate_plan),
            Receipt(backend=backend('receipt')),trial.Intent(backend=backend('intent'),lock=lock('intent')))


def point(raw,book,chapter,row):
    if not isinstance(raw,str) or raw.count(trial.TEXT)!=1 or row.get('bookId')!=book or str(row.get('chapterUid'))!=chapter:
        raise ValueError('txt_bookmark/source')
    source=raw.removeprefix('\ufeff');bom=int(raw.startswith('\ufeff'))
    preview=source[:140].strip()
    if (not source.startswith('A self-authored test begins') or row.get('range')!='0'
            or row.get('markText')!=preview or source.count(preview)!=1):
        raise ValueError('txt_bookmark/point')
    first,_=PlainSource(raw).locate(preview)
    if first!=bom:raise ValueError('txt_bookmark/point')
    return dict(chapter_offset=first)


def run(saved,session,native,grant,journal,receipt,intent,command,*,apply=False,runner=run_bookmark,uploader=upload_run):
    if receipt.backend.load() is not None:raise ValueError('txt_bookmark/consumed')
    def upload(probe,journal_arg,grant_arg,grant_check,source,*,apply,cleanup_gate):
        if journal_arg is not journal or grant_arg!=grant or receipt.backend.load() is not None:
            raise ValueError('txt_bookmark/authority')
        return uploader(probe,journal,grant,grant_check,source,apply=apply,cleanup_gate=cleanup_gate,
                        fixture_builder=lambda:trial.BODY,prepare_plan=prepare_plan,check_plan=check_plan,
                        fixture_extension='txt',readback_tries=7,notify_receipt=receipt.record)
    def authority(journal_arg,claim,target,owner,grant_arg,same_grant):
        return fixture_authorized(journal_arg,claim,target,owner,grant_arg,same_grant,receipt)
    return runner(saved,session,native,grant,journal,intent,command,apply=apply,uploader=upload,
                  prepare_fn=trial.prepare,source_format='web_txt',source_marker=trial.TEXT,point_fn=point,
                  upload_success='TXT_IMPORT_AND_SOURCE_VERIFIED',fixture_authorized=authority,
                  result_label='CB_NATIVE_TXT_START_BOOKMARK_VERIFIED',allow_zero_version=True)


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
    except Exception:report=dict(result='UNVERIFIED',phase='setup',native_writes_allocated=0)
    finally:
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(report));return int(report.get('result') not in ('READ_ONLY_PREVIEW','CB_NATIVE_TXT_START_BOOKMARK_VERIFIED'))


if __name__=='__main__':raise SystemExit(main())
