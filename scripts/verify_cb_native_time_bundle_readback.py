#!/usr/bin/env python3
"""Read-only audit after an acknowledged imported-book time transfer."""
import argparse,json,resource

from cb_native_time_bundle_audit_store import AuditStore
from cb_native_time_bundle_gate import DispatchGate
from cb_native_time_bundle_readback import run
from cb_native_time_capture_bundle import store
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-capture',action='store_true');args=parser.parse_args(argv)
    result=dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0,real_accounting_verified=False)
    if not args.saved_capture:
        print(json.dumps(result));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    try:
        gate=DispatchGate();state,_receipt=gate.read()
        if not state or state['phase']!='acknowledged':result['result']='NOT_READY'
        else:result=run(SessionStore(),NativeSessionStore(),store(),gate,AuditStore())
    except (Exception,KeyboardInterrupt):result['result']='UNVERIFIED'
    print(json.dumps(result));return int(result['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
