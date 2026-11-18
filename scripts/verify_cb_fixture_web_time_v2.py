#!/usr/bin/env python3
"""Independent Web-time fixture trial with a private, durable baseline."""
import argparse
import json
from pathlib import Path
import resource
import tempfile
from cb_fixture_position_intent import Intent as SeedIntent
from cb_fixture_web_time_evidence import Evidence
from cb_fixture_web_time_intent import Intent as TimeIntent
from secure_native_session import NativeSessionStore,project_lock
from secure_weread_session import ACCOUNT,MacKeychain,SessionStore
from synthetic_epub_trial import Journal
from verify_cb_fixture_web_time import run


def stores():
    def backend(part):return MacKeychain(service='org.codex.weread.cb-web-time-fixture-'+part+'-v2',account=ACCOUNT)
    def lock(part):
        path=Path(tempfile.gettempdir())/('codex-cb-web-time-fixture-'+part+'-v2-'+ACCOUNT+'.lock')
        return lambda:project_lock(path)
    return (Journal(backend=backend('upload'),lock=lock('upload')),
            SeedIntent(backend=backend('seed'),lock=lock('seed')),
            TimeIntent(backend=backend('send'),lock=lock('send')))


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');parser.add_argument('--apply',action='store_true')
    args=parser.parse_args(argv)
    if args.apply and not args.saved_session:parser.error('apply requires saved session')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY',account_data_writes=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=None
    try:
        session=SessionStore();saved=session.load();native=NativeSessionStore();grant=native.load(saved['vid'])
        evidence=Evidence()
        if evidence.backend.load() is not None:raise ValueError('cb_time/evidence_occupied')
        report=run(saved,session,native,grant,*stores(),evidence=evidence,apply=args.apply)
    except Exception:report=dict(result='UNVERIFIED',account_data_writes=0)
    finally:
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(report));return int(report['result'] not in ('READ_ONLY_PREVIEW','FIXTURE_WEB_TIME_VERIFIED'))


if __name__=='__main__':raise SystemExit(main())
