#!/usr/bin/env python3
"""Fresh one-shot native reading-time fixture with durable baseline snapshots."""
import argparse,json,resource,tempfile
from pathlib import Path
from cb_fixture_native_time_intent import Intent as UiIntent
from cb_fixture_position_intent import Intent as SeedIntent
from cb_fixture_web_time_evidence import Evidence
from secure_native_session import NativeSessionStore,project_lock
from secure_weread_session import ACCOUNT,MacKeychain,SessionStore
from synthetic_epub_trial import Journal
from verify_cb_fixture_native_time_trial import run


def backend(part):return MacKeychain(service='org.codex.weread.cb-native-time-fixture-'+part+'-v2',account=ACCOUNT)
def lock(part):
    path=Path(tempfile.gettempdir())/('codex-cb-native-time-fixture-'+part+'-v2-'+ACCOUNT+'.lock')
    return lambda:project_lock(path)
def stores():
    return (Journal(backend=backend('upload'),lock=lock('upload')),
            SeedIntent(backend=backend('seed'),lock=lock('seed')),
            UiIntent(backend=backend('ui'),lock=lock('ui')))
def evidence(index):
    if type(index) is not int or index not in (1,2):raise ValueError('native_time/evidence')
    name='baseline-'+str(index)
    return Evidence(backend=backend(name),lock=lock(name))


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');parser.add_argument('--apply',action='store_true')
    parser.add_argument('--runner',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    if args.apply and not args.saved_session or args.saved_session and not args.runner:parser.error('saved session and runner required')
    if args.runner and not args.saved_session:parser.error('runner requires saved session')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY',account_data_writes=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));saved=grant=None
    try:
        session=SessionStore();saved=session.load();native=NativeSessionStore();grant=native.load(saved['vid'])
        if any(evidence(index).backend.load() is not None for index in (1,2)):raise ValueError('native_time/evidence_occupied')
        report=run(saved,session,native,grant,*stores(),args.runner,evidence_factory=evidence,apply=args.apply)
    except Exception:report=dict(result='UNVERIFIED',account_data_writes=0)
    finally:
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(report));return int(report['result'] not in ('READ_ONLY_PREVIEW','FIXTURE_NATIVE_TIME_VERIFIED'))


if __name__=='__main__':raise SystemExit(main())
