#!/usr/bin/env python3
"""Read-only CB cross-day preflight; no signing, claim or upload."""
import argparse,json,resource

from cb_native_time_bundle_audit_store import AuditStore
from cb_native_time_bundle_gate import DispatchGate
from cb_native_time_bundle_preflight import run
from cb_native_time_capture_bundle import store
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-capture',action='store_true');args=parser.parse_args(argv)
    if not args.saved_capture:
        print(json.dumps(dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0));packet=None
    try:report,packet=run(store(),SessionStore(),NativeSessionStore(),DispatchGate(),AuditStore())
    except Exception:report=dict(result='UNVERIFIED',account_data_posts=0,authentication_posts=0)
    finally:
        if packet:packet.close()
    print(json.dumps(report));return int(report['result'] not in ('NOT_YET_HISTORICAL','CB_CROSS_DAY_READONLY_VERIFIED'))


if __name__=='__main__':raise SystemExit(main())
