#!/usr/bin/env python3
"""One synthetic imported EPUB, native pin/unpin, and independent readbacks."""
import argparse
import json
from pathlib import Path
import resource
import tempfile
from urllib.parse import urlencode

from cloud_group_fixture import Journal
from imported_pin_audit_binding import create as create_binding
from native_direct_time_trial_store import Intent
from native_imported_pin_fixture_trial import run as native_trial
from secure_native_session import NativeSessionStore, project_lock
from secure_weread_session import ACCOUNT, MacKeychain, SessionStore
from synthetic_format_trial import TargetReceipt
from verify_eink_login import BASE, NativeProbe
from verify_imported_pin_fixture import audit, execute, validate_receipts
from verify_imported_pin_trial import intents as prior_intents
from verify_native_metadata import normalize_native
from verify_shelf_flags import WebFlagsProbe
from verify_translation_preflight import save_refreshed_web_session


def backend(name):
    return MacKeychain(service='org.codex.weread.native-imported-pin-fixture-'+name+'-v1',account=ACCOUNT)


def lock(name):
    path=Path(tempfile.gettempdir())/('codex-native-imported-pin-fixture-'+name+'-'+ACCOUNT+'.lock')
    return lambda:project_lock(path)


def stores():
    journal=Journal(backend=backend('upload'),lock=lock('upload'))
    receipt=TargetReceipt('epub',backend=backend('target'),scope='group-fixture')
    records={name:Intent(backend=backend(name),lock=lock(name)) for name in ('baseline','pin','restore')}
    return journal,receipt,records


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    mode=parser.add_mutually_exclusive_group();mode.add_argument('--apply',action='store_true');mode.add_argument('--audit',action='store_true');mode.add_argument('--bind-audit',action='store_true')
    parser.add_argument('--native-command',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    if (args.apply or args.audit or args.bind_audit or args.native_command) and not args.saved_session:
        parser.error('requested mode requires --saved-session')
    if args.apply and (not args.native_command or args.native_command.count('--imported')!=1 or '--armed' in args.native_command):
        parser.error('apply requires an imported native command without --armed')
    if args.native_command and not args.apply:parser.error('native command requires --apply')
    if not args.saved_session:
        print(json.dumps({'result':'OFFLINE_ONLY','account_data_writes':0}));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=web=None;store=SessionStore()
    report={'result':'UNVERIFIED','phase':'preflight','existing_book_writes':0}
    execution_lock=Path(tempfile.gettempdir())/('codex-native-imported-pin-fixture-execution-'+ACCOUNT+'.lock')
    try:
        with project_lock(execution_lock):
            saved=store.load();web=WebFlagsProbe();web.vid=saved['vid']
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account();journal,receipt,records=stores()
            prior,_=prior_intents()['pin'].read();protected=prior['plan']['selection']['book_id'] if prior else None
            binding=backend('audit-binding');native_store=NativeSessionStore()
            if args.bind_audit:
                grant=native_store.load(saved['vid'])
                try:
                    _target,_base,pin,restore=validate_receipts(saved,grant,journal,receipt,records,protected)
                    create_binding(saved['vid'],grant,pin,restore,binding)
                    report={'result':'AUDIT_BINDING_VERIFIED','account_data_writes':0}
                finally:grant.clear()
            elif args.audit:
                report=audit(saved,native_store,web,journal,receipt,records,protected,binding=binding)
            else:
                native=NativeProbe()
                def executor(grant,target,before,observe,current,trial_records,mark_armed):
                    if not current():raise ValueError('native_imported_pin/session')
                    raw=native.request('metadata',BASE+'/book/info?'+urlencode({'bookId':target}),credentials=grant)
                    metadata=normalize_native(raw,target)
                    return native_trial(grant,target,before,observe,current,trial_records,metadata,args.native_command,mark_armed)
                report=execute(saved,native_store,web,journal,receipt,records,protected,apply=args.apply,
                               native=native,trial_executor=executor if args.apply else None)
            web.verify_account()
    except Exception:
        report['result']='UNVERIFIED'
    finally:
        if web and saved and web.authenticated:
            try:report['web_session_saved']=save_refreshed_web_session(store,saved,web)
            except Exception:report.update(result='UNVERIFIED',session_preservation_failed=True)
        if web:web.close()
        if saved:saved.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2))
    return 0 if report['result'] in ('READ_ONLY_PREVIEW','READ_ONLY_RESTORED','READ_ONLY_SNAPSHOT_CHANGED','AUDIT_BINDING_VERIFIED','PASS') else 1


if __name__=='__main__':raise SystemExit(main())
