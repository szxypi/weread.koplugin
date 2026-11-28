#!/usr/bin/env python3
"""Read-only audit of an already acknowledged native time request."""
import argparse
import json
import re
import resource

from native_time_bundle_audit_store import AuditStore
from native_time_bundle_fresh_audit import FreshAuditStore
from native_time_bundle_gate import DispatchGate
from native_time_bundle_readback import run
from native_time_capture_bundle import CaptureBundleStore
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_native_time_capture import XhtmlSource


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--fresh-shelf',action='store_true',help='inspect the separately sealed fresh-shelf audit')
    args=parser.parse_args(argv)
    if args.fresh_shelf and not args.saved_session:parser.error('fresh-shelf inspection requires a saved session')
    result={'result':'OFFLINE_ONLY','account_data_posts':0,'authentication_posts':0,'real_accounting_verified':False}
    saved=grant=web=None
    try:
        if args.saved_session:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0))
            gate=DispatchGate();state,_receipt=gate.read()
            if state is None or state['phase']!='acknowledged':
                result['result']='NOT_READY'
            else:
                store=CaptureBundleStore();audit=FreshAuditStore() if args.fresh_shelf else AuditStore()
                session=SessionStore();native=NativeSessionStore()
                saved=session.load();grant=native.load(saved['vid'])
                web=XhtmlSource();web.vid=saved['vid']
                for key,value in saved['cookies'].items():web.set_cookie(key,value)
                current=lambda:session.load()==saved and native.load(saved['vid'])==grant
                result=run(saved=saved,grant=grant,store=store,gate=gate,audit=audit,current=current,web=web)
    except (Exception,KeyboardInterrupt) as error:
        result['result']='UNVERIFIED'
        if isinstance(error,ValueError) and re.fullmatch(r'bundle_readback/[a-z_]+',str(error)):
            result['reason']=str(error)
    finally:
        if web:
            web.shards.clear()
            if hasattr(web,'_time_catalog_pair'):web._time_catalog_pair.clear()
            web.close()
        for value in (saved,grant):
            if value:value.clear()
    print(json.dumps(result,ensure_ascii=False,indent=2))
    return int(result['result'] not in ('OFFLINE_ONLY','NOT_READY','READBACK_MATCH'))


if __name__=='__main__':raise SystemExit(main())
