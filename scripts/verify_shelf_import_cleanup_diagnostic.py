#!/usr/bin/env python3
"""One synthetic EPUB import/removal to diagnose full bookshelf snapshot changes."""
import argparse
import json
from pathlib import Path
import resource
import tempfile

from cloud_group_fixture import Journal
from native_direct_time_trial_store import Intent
from secure_native_session import NativeSessionStore, project_lock
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from shelf_import_cleanup_diagnostic import audit, bind_audit, execute
from synthetic_format_trial import TargetReceipt
from verify_imported_pin_fixture import stores as protocol_stores
from verify_imported_pin_trial import intents as prior_intents
from verify_owner_native_imported_pin_fixture import stores as native_stores
from verify_shelf_flags import WebFlagsProbe
from verify_translation_preflight import save_refreshed_web_session


def backend(name):return MacKeychain(service='org.codex.weread.import-cleanup-diagnostic-'+name+'-v1',account=ACCOUNT)


def lock(name):
    path=Path(tempfile.gettempdir())/('codex-import-cleanup-diagnostic-'+name+'-'+ACCOUNT+'.lock')
    return lambda:project_lock(path)


def stores():
    return (Journal(backend=backend('upload'),lock=lock('upload')),
            TargetReceipt('epub',backend=backend('target'),scope='group-fixture'),
            Intent(backend=backend('baseline'),lock=lock('baseline')))


def protected_targets():
    protected=set();prior,_=prior_intents()['pin'].read()
    if prior:protected.add(prior['plan']['selection']['book_id'])
    for get_stores in (protocol_stores,native_stores):
        journal,_receipt,_records=get_stores();state,_=journal.read()
        if state and state.get('target'):protected.add(state['target'])
    return protected


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    mode=parser.add_mutually_exclusive_group();mode.add_argument('--apply',action='store_true');mode.add_argument('--audit',action='store_true');mode.add_argument('--bind-audit',action='store_true')
    args=parser.parse_args(argv)
    if (args.apply or args.audit or args.bind_audit) and not args.saved_session:parser.error('mode requires --saved-session')
    if not args.saved_session:
        print(json.dumps({'result':'OFFLINE_ONLY','account_data_writes':0}));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=web=None;session=SessionStore()
    report={'result':'UNVERIFIED','phase':'preflight','existing_book_writes':0}
    execution_lock=Path(tempfile.gettempdir())/('codex-import-cleanup-diagnostic-execution-'+ACCOUNT+'.lock')
    try:
        with project_lock(execution_lock):
            saved=session.load();web=WebFlagsProbe();web.vid=saved['vid']
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account();journal,receipt,baseline=stores();protected=protected_targets();native_store=NativeSessionStore()
            if args.bind_audit:
                grant=native_store.load(saved['vid'])
                try:bind_audit(saved,grant,journal,receipt,baseline,protected,backend('audit-binding'))
                finally:grant.clear()
                report={'result':'AUDIT_BINDING_VERIFIED','account_data_writes':0}
            elif args.audit:
                report=audit(saved,native_store,web,journal,receipt,baseline,protected,binding_backend=backend('audit-binding'))
            else:
                report=execute(saved,native_store,web,journal,receipt,baseline,protected,apply=args.apply)
            web.verify_account()
    except Exception:
        report['result']='UNVERIFIED'
    finally:
        if web and saved and web.authenticated:
            try:report['web_session_saved']=save_refreshed_web_session(session,saved,web)
            except Exception:report.update(result='UNVERIFIED',session_preservation_failed=True)
        if web:web.close()
        if saved:saved.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2))
    return 0 if report['result'] in ('READ_ONLY_PREVIEW','READ_ONLY_RESTORED','READ_ONLY_SNAPSHOT_CHANGED','AUDIT_BINDING_VERIFIED','RESTORED_FULL') else 1


if __name__=='__main__':raise SystemExit(main())
