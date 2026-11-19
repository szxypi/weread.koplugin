#!/usr/bin/env python3
"""One isolated TXT native-selection highlight roundtrip; offline by default."""
import argparse
import json
from pathlib import Path
import resource
import tempfile

import cb_txt_highlight_trial as trial
import verify_cb_txt_highlight_trial as fixture
from personal_upload_trial import Journal
from secure_native_session import NativeSessionStore,project_lock
from secure_weread_session import ACCOUNT,MacKeychain,SessionStore
from txt_coordinates import PlainSource
from verify_cb_fixture_highlight_native import run as run_highlight
from verify_cb_txt_fixture import Receipt
from verify_synthetic_epub_upload import run as upload_run


def stores():
    def backend(part):return MacKeychain(service='org.codex.weread.cb-txt-native-highlight-'+part+'-v1',account=ACCOUNT)
    def lock(part):
        path=Path(tempfile.gettempdir())/('codex-cb-txt-native-highlight-'+part+'-'+ACCOUNT+'.lock')
        return lambda:project_lock(path)
    return (Journal(backend=backend('upload'),lock=lock('upload'),validator=fixture.validate_plan),
            Receipt(backend=backend('receipt')),trial.Intent(backend=backend('intent'),lock=lock('intent')))


def span(raw,book,chapter,row):
    if (not isinstance(raw,str) or raw.count(trial.TEXT)!=1 or row.get('markText')!=trial.TEXT
            or str(row.get('chapterUid'))!=chapter):raise ValueError('txt_native_highlight/source')
    first,last=PlainSource(raw).locate(trial.TEXT);bom=int(raw.startswith('\ufeff'))
    if row.get('range')!=f'{first-bom}-{last-bom}':raise ValueError('txt_native_highlight/range')
    return dict(first=first,last=last)


def run(saved,session,native,grant,journal,receipt,intent,command,*,apply=False,runner=run_highlight,uploader=upload_run):
    if receipt.backend.load() is not None:raise ValueError('txt_native_highlight/consumed')
    def upload(probe,journal_arg,grant_arg,grant_check,source,*,apply,cleanup_gate):
        if journal_arg is not journal or grant_arg!=grant or receipt.backend.load() is not None:
            raise ValueError('txt_native_highlight/authority')
        return uploader(probe,journal,grant,grant_check,source,apply=apply,cleanup_gate=cleanup_gate,
                        fixture_builder=lambda:trial.BODY,prepare_plan=fixture.prepare_plan,check_plan=fixture.check_plan,
                        fixture_extension='txt',readback_tries=7,notify_receipt=receipt.record)
    def authority(journal_arg,claim,target,owner,grant_arg,same_grant):
        return fixture.fixture_authorized(journal_arg,claim,target,owner,grant_arg,same_grant,receipt)
    def prepare(owner,book,attempt,sample,version,baseline):
        return trial.prepare(owner,book,attempt,sample,version,baseline,range_unit='utf16')
    return runner(saved,session,native,grant,journal,intent,command,apply=apply,uploader=upload,
                  prepare_fn=prepare,source_format='web_txt',source_marker=trial.TEXT,span_fn=span,
                  upload_success='TXT_IMPORT_AND_SOURCE_VERIFIED',fixture_authorized=authority,
                  result_label='CB_NATIVE_TXT_HIGHLIGHT_VERIFIED')


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
    print(json.dumps(report));return int(report.get('result') not in ('READ_ONLY_PREVIEW','CB_NATIVE_TXT_HIGHLIGHT_VERIFIED'))


if __name__=='__main__':raise SystemExit(main())
