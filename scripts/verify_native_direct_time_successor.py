#!/usr/bin/env python3
"""One new, nonoverlapping direct-time trial after an acknowledged prior send.

Offline by default. The original Keychain receipt remains unchanged and the
new trial has its own permanent single-use claim. No previous interval may be
replayed. --saved-session performs only a dispatch-denied rehearsal.
"""
import argparse
import json
from pathlib import Path
import resource
import tempfile

from native_direct_time_trial_store import Intent
from native_time_bundle_selection import native_digest
from native_time_capture_evidence import account_key
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT, MacKeychain
from verify_native_direct_time_trial import run

SERVICE='org.codex.weread.direct-current-time-owner-successor-v1'


def integer(value,low,high):
    return type(value) is int and low<=value<=high


class PriorGuard:
    def __init__(self,store):
        self.store=store
        value,self.receipt=store.read()
        if not value or value.get('phase') not in ('acknowledged','verified') or not isinstance(self.receipt,bytes):
            raise ValueError('direct_time/prior')
        plan=value.get('plan');selection=plan.get('selection') if isinstance(plan,dict) else None
        record=plan.get('record') if isinstance(plan,dict) else None;body=plan.get('body') if isinstance(plan,dict) else None
        if (not isinstance(selection,dict) or not isinstance(record,dict) or not isinstance(body,dict)
                or record.get('phase')!='claimed' or record.get('request_hash')!=native_digest(body)
                or not isinstance(record.get('account'),str) or not isinstance(selection.get('protocol_rows'),list)
                or not 1<=len(selection['protocol_rows'])<=20):
            raise ValueError('direct_time/prior')
        self.owner=record['account'];self.end=0;total=0
        for row in selection['protocol_rows']:
            if (not isinstance(row,dict) or not integer(row.get('start_time'),1,4102444800)
                    or not integer(row.get('duration'),1,60)):
                raise ValueError('direct_time/prior')
            total+=row['duration'];self.end=max(self.end,row['start_time']+row['duration'])
        if total!=selection.get('seconds'):raise ValueError('direct_time/prior')

    def check(self,grant,selection=None,record=None):
        value,receipt=self.store.read()
        if (receipt!=self.receipt or not value or value.get('phase') not in ('acknowledged','verified')
                or not isinstance(grant,dict) or self.owner!=account_key(grant.get('vid'))):
            raise ValueError('direct_time/prior')
        if selection is not None:
            rows=selection.get('protocol_rows') if isinstance(selection,dict) else None
            if not isinstance(rows,list) or not rows or any(not isinstance(row,dict)
                    or not integer(row.get('start_time'),self.end,4102444800) for row in rows):
                raise ValueError('direct_time/overlap')
        if record is not None and (not isinstance(record,dict) or record.get('account')!=self.owner):
            raise ValueError('direct_time/prior')
        return True


def successor_store():
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
        prior=PriorGuard(Intent());successor=successor_store()
    except Exception:
        report=dict(result='UNVERIFIED',phase='prior',account_data_posts=0,authentication_posts=0,
            dispatch_may_have_occurred=False,private_data_in_report=False)
    else:
        report=run(apply=args.apply,intent=successor,predecessor=prior)
        try:report['prior_record_unchanged']=prior.store.read()[1]==prior.receipt
        except Exception:report['prior_record_unchanged']=False
    print(json.dumps(report));return int(report['result'] not in
        ('DIRECT_NATIVE_TIME_DRY_VERIFIED','DIRECT_NATIVE_TIME_ACCOUNTING_VERIFIED') or not report.get('prior_record_unchanged'))


if __name__=='__main__':raise SystemExit(main())
