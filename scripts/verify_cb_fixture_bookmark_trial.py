#!/usr/bin/env python3
"""One isolated imported-book bookmark create/delete trial; offline by default."""
import argparse
import json
from pathlib import Path
import resource
import tempfile

from bookmark_trial_model import observe
from cb_fixture_bookmark_trial import Intent,execute,prepare
from secure_native_session import NativeSessionStore,project_lock
from secure_weread_session import ACCOUNT,MacKeychain,SessionStore
from synthetic_epub_trial import Journal
from verify_cb_fixture_highlight_trial import run as run_fixture

UPLOAD_SERVICE='org.codex.weread.cb-fixture-bookmark-upload-v1'


def stores():
    backend=MacKeychain(service=UPLOAD_SERVICE,account=ACCOUNT)
    path=Path(tempfile.gettempdir())/('codex-cb-fixture-bookmark-upload-'+ACCOUNT+'.lock')
    return Journal(backend=backend,lock=lambda:project_lock(path)),Intent()


def run(saved,session,native_store,grant,journal,intent,*,apply=False,**dependencies):
    outcome={}
    def final_check(baseline,current,body):
        return observe(baseline,current,body,deleted=True) is None
    def bounded(*args):
        outcome.update(execute(*args));return outcome
    report=run_fixture(saved,session,native_store,grant,journal,intent,apply=apply,prepare_fn=prepare,
        execute_fn=bounded,final_check=final_check,result_label='CB_FIXTURE_BOOKMARK_VERIFIED',**dependencies)
    if report['result']=='CB_FIXTURE_BOOKMARK_VERIFIED':report['server_preview_returned']=outcome['server_preview_returned']
    return report


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');parser.add_argument('--apply',action='store_true')
    args=parser.parse_args(argv)
    if args.apply and not args.saved_session:parser.error('apply requires saved session')
    if not args.saved_session:print(json.dumps(dict(result='OFFLINE_ONLY',annotation_posts=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=None
    try:
        session=SessionStore();saved=session.load();native=NativeSessionStore();grant=native.load(saved['vid'])
        report=run(saved,session,native,grant,*stores(),apply=args.apply)
    except Exception:report=dict(result='UNVERIFIED',phase='setup',annotation_posts=0)
    finally:
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(report,ensure_ascii=False));return int(report['result'] not in ('READ_ONLY_PREVIEW','CB_FIXTURE_BOOKMARK_VERIFIED'))


if __name__=='__main__':raise SystemExit(main())
