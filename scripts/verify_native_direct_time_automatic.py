#!/usr/bin/env python3
"""One new supervised automatic-time trial using a shortened timer.

The independent prior receipts must remain intact, all time windows must be
new and nonoverlapping, and this trial has its own permanent single-use claim.
Offline by default; --saved-session denies dispatch unless --apply is set.
"""
import argparse
import json
from pathlib import Path
import resource
import tempfile

from native_direct_time_trial_store import Intent
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,MacKeychain
from verify_native_direct_time_successor import PriorGuard,successor_store
from verify_native_direct_time_trial import run

SERVICE='org.codex.weread.direct-current-time-owner-auto-v1'


class PriorGuards:
    def __init__(self,stores):
        self.guards=[PriorGuard(store) for store in stores]
        if len(self.guards)!=2:raise ValueError('direct_time/prior')
    def check(self,grant,selection=None,record=None):
        for guard in self.guards:guard.check(grant,selection,record)
        return True
    def unchanged(self):
        return all(guard.store.read()[1]==guard.receipt for guard in self.guards)


def auto_store():
    path=Path(tempfile.gettempdir())/('codex-direct-current-time-'+ACCOUNT+'.lock')
    return Intent(backend=MacKeychain(service=SERVICE,account=ACCOUNT),lock=lambda:project_lock(path))


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--apply',action='store_true');args=parser.parse_args(argv)
    if args.apply and not args.saved_session:parser.error('--apply requires --saved-session')
    if not args.saved_session:
        print(json.dumps(dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    try:
        previous=successor_store()
        if previous.read()[0].get('phase')!='verified':raise ValueError('direct_time/prior')
        guards=PriorGuards([Intent(),previous]);intent=auto_store()
    except Exception:
        report=dict(result='UNVERIFIED',phase='prior',account_data_posts=0,authentication_posts=0,
            dispatch_may_have_occurred=False,private_data_in_report=False)
    else:
        report=run(apply=args.apply,intent=intent,predecessor=guards,automatic=True)
        try:report['prior_records_unchanged']=guards.unchanged()
        except Exception:report['prior_records_unchanged']=False
    print(json.dumps(report));return int(report['result'] not in
        ('DIRECT_NATIVE_TIME_DRY_VERIFIED','DIRECT_NATIVE_TIME_ACCOUNTING_VERIFIED') or not report.get('prior_records_unchanged'))


if __name__=='__main__':raise SystemExit(main())
