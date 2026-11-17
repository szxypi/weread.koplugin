#!/usr/bin/env python3
"""Synthetic-only parity check of a native signed body and one-shot guard."""
import argparse
import json
import subprocess

from native_time_bundle_gate import DispatchGate,verify_request
from selection_trial_mock import credentials
from test_native_time_capture_evidence import bundle,make_fixture
from test_secure_native_session import Backend
from txt_full_summary import digest


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    report=dict(result='OFFLINE_ONLY',synthetic_only=True,account_data_posts=0,authentication_posts=0)
    try:
        if args.lua_command:
            plan,ledger,coverage=make_fixture();grant=credentials();plan['device_sha256']=digest(grant['deviceId'])
            proof=bundle(ledger,coverage);ledger.close();coverage.close()
            captured=dict(plan=plan,evidence=proof);now=plan['not_before']+20
            rows=[{key:row[key] for key in ('start_time','duration','time_zone','book_version')} for row in plan['rows']]
            payload=dict(credentials=grant,book_id=plan['book_id'],rows=rows,guest_token='synthetic-guest',
                         config_token='synthetic-config',now=now,random=123,
                         envelope=dict(timestamp=now*1000,random=456,current_zone='+08:00'))
            child=subprocess.run(args.lua_command,input=json.dumps(payload).encode(),stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=60)
            if child.returncode or len(child.stdout)>65536:raise ValueError('bundle_gate/lua')
            native=json.loads(child.stdout)
            if not isinstance(native,dict) or set(native)!={'result','body'} or native['result']!='PASS':raise ValueError('bundle_gate/lua')
            body=native['body'];verify_request(captured,grant,body,'synthetic-guest','synthetic-config',now,'+08:00')
            gate=DispatchGate(Backend(),clock=lambda:now,zone=lambda:'+08:00')
            receipt=gate.reserve(captured,grant);receipt=gate.claim(receipt,captured,grant,body,'synthetic-guest','synthetic-config')
            if gate.read()[0]['phase']!='claimed':raise ValueError('bundle_gate/claim')
            gate.acknowledge(receipt,{'succ':1})
            if gate.read()[0]['phase']!='acknowledged':raise ValueError('bundle_gate/ack')
            report.update(result='SYNTHETIC_NATIVE_GATE_VERIFIED',native_signed_body_matches=True,
                          durable_claim_before_ack=True,historical_accounting_verified=False)
    except Exception:
        report['result']='UNVERIFIED'
    print(json.dumps(report))
    return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
