#!/usr/bin/env python3
"""One fresh self-authored TXT, with a non-BMP boundary; offline by default.

Upload, first position, manual choices and cleanup have separate durable
one-shot records. An uncertain step stops without replay or automatic cleanup.
"""
import argparse
import hashlib
import json
from pathlib import Path
import resource
import tempfile

from cb_existing_position_intent import Intent as ManualIntent
from cb_initial_fixture_intent import Intent as InitialIntent
from cb_txt_unicode_fixture_plan import CONTEXT, plan
from personal_upload_trial import Journal as BaseJournal, check, hash_value, prepare, validate
from secure_native_session import NativeSessionStore, project_lock
from secure_shelf_experiment import canonical
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from txt_coordinates import PlainSource
from verify_cb_initial_fixture_ui_trial import run, ui_command
from verify_cb_txt_fixture import MARKER, Receipt
from verify_cb_txt_manual_fixture_ui_trial import manual_command, manual_trial
from verify_synthetic_epub_upload import run as upload_run

BODY=(MARKER+'\r\n'+CONTEXT+'\r\nA final distinct line for UTF-16 position verification.\r\n').encode('utf-8')


def validate_plan(value):
    validate(value)
    if value['body_sha256']!=hashlib.sha256(BODY).hexdigest():raise ValueError('cb_txt_unicode/fixture')
    return value


def prepare_plan(credentials,shelf,name):
    return validate_plan(prepare(credentials,shelf,name,BODY))


def check_plan(value,credentials,shelf,target=None,expected=False):
    return check(value,credentials,shelf,target,expected,validator=validate_plan)


def stores():
    def backend(suffix):return MacKeychain(service='org.codex.weread.cb-txt-unicode-ui-'+suffix+'-v1',account=ACCOUNT)
    def lock(suffix):
        path=Path(tempfile.gettempdir())/('codex-cb-txt-unicode-ui-'+suffix+'-'+ACCOUNT+'.lock')
        return lambda:project_lock(path)
    return (BaseJournal(backend=backend('upload'),lock=lock('upload'),validator=validate_plan),
            Receipt(backend=backend('receipt')),
            InitialIntent(backend=backend('initial'),lock=lock('initial')),
            ManualIntent(backend=backend('manual'),lock=lock('manual')))


def execute(saved,session,native,grant,journal,receipt,initial,manual,first_command,second_command,*,apply=False,
            trial=run,upload=upload_run,manual_runner=manual_trial):
    if receipt.backend.load() is not None or manual.backend.load() is not None:
        return dict(result='UNVERIFIED',phase='preflight',account_data_writes_known=0,position_writes_uncertain=False)
    def uploader(probe,journal_arg,grant_arg,grant_check,source,*,apply,cleanup_gate):
        if journal_arg is not journal or grant_arg!=grant or receipt.backend.load() is not None:
            raise ValueError('cb_txt_unicode/authority')
        return upload(probe,journal,grant,grant_check,source,apply=apply,cleanup_gate=cleanup_gate,
                      fixture_builder=lambda:BODY,prepare_plan=prepare_plan,check_plan=check_plan,
                      fixture_extension='txt',readback_tries=7,notify_receipt=receipt.record)
    def fixture_authorized(uploaded,claimed,target,owner):
        state,current=uploaded.read()
        if (not state or current!=claimed or state.get('phase')!='imported' or state.get('target')!=target
                or state['plan'].get('owner')!=owner):return False
        expected=canonical(dict(schema=1,owner=owner,attempt=state['attempt'],target=target,
                                plan_sha256=hash_value(state['plan'])))
        return receipt.backend.load()==expected
    def after(context,report):return manual_runner(context,report,manual,second_command)
    result=trial(saved,session,native,grant,journal,initial,first_command,apply=apply,uploader=uploader,
                 source_format='web_txt',source_marker=MARKER,position_planner=plan,
                 summary_planner=lambda sample,target:PlainSource(sample['source']).excerpt(target['first'])['text'],
                 upload_success='TXT_IMPORT_AND_SOURCE_VERIFIED',fixture_authorized=fixture_authorized,after_verified=after)
    if result.get('result')=='CB_FIRST_NATIVE_UI_VERIFIED' and len(result.get('manual_stages',[]))==2:
        result['result']='CB_TXT_UNICODE_NATIVE_UI_VERIFIED'
    return result


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true');parser.add_argument('--apply',action='store_true')
    args=parser.parse_args(argv)
    if args.apply and not args.saved_session:parser.error('apply requires saved session')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY',account_data_writes_known=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=None
    try:
        first,second=ui_command(),manual_command()
        session=SessionStore();saved=session.load();native=NativeSessionStore();grant=native.load(saved['vid'])
        result=execute(saved,session,native,grant,*stores(),first,second,apply=args.apply)
    except Exception:
        result=dict(result='UNVERIFIED',phase='unknown' if args.apply else 'preflight',
                    account_data_writes_known=None if args.apply else 0,position_writes_uncertain=args.apply)
    finally:
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(result));return int(result['result'] not in ('READ_ONLY_PREVIEW','CB_TXT_UNICODE_NATIVE_UI_VERIFIED'))


if __name__=='__main__':raise SystemExit(main())
