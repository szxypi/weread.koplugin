#!/usr/bin/env python3
"""Read-only native worker rehearsal for the independent time capture.

No time report or authorization renewal can be sent. Existing trial journals
are checked for change but never reused or overwritten.
"""
import argparse
from copy import deepcopy
import json
import re
import resource
import time

from native_time_bundle_audit_store import AuditStore as LegacyAudit
from native_time_bundle_evidence import IndependentCaptureEvidence
from native_time_bundle_fresh_audit import FreshAuditStore
from native_time_bundle_gate import DispatchGate,day
from native_time_bundle_preparation import SigningRead,SigningInputs
from native_time_capture_fresh_bundle import store as capture_store
from native_time_independent_audit import IndependentAudit
from native_time_independent_broker import AccountBinding,Prepared,execute as broker_execute
from native_time_independent_gate import IndependentGate
from secure_native_session import NativeSessionStore
from secure_weread_session import MacKeychain,SessionStore
from verify_fresh_time_capture_readonly import run as preflight_run
from verify_native_time_fresh_dry import trusted_command


def run(store,session,native,gate,audit,legacy_gate,legacy_audit,legacy_original,*,clock=time.time,
        attest=trusted_command,preflight=preflight_run,signer=SigningRead,broker=broker_execute,binding_type=AccountBinding):
    result=dict(result='UNVERIFIED',account_data_posts=0,authentication_posts=0,dispatch_may_have_occurred=False,
                real_accounting_verified=False,private_data_in_report=False)
    binding=prepared=None
    try:
        real=any(isinstance(getattr(item,'backend',None),MacKeychain) for item in (store,gate,audit,legacy_gate,legacy_audit,legacy_original))
        if real and (clock is not time.time or attest is not trusted_command or preflight is not preflight_run
                or signer is not SigningRead or broker is not broker_execute or binding_type is not AccountBinding
                or type(session) is not SessionStore or type(native) is not NativeSessionStore):
            raise ValueError('independent_dry/override')
        bundle,receipt=store.read()
        if not bundle or receipt is None:raise ValueError('independent_dry/capture')
        plan=bundle['plan'];now=int(clock())
        if now<plan['not_before'] or day(now)<=day(plan['start_time']):
            result['result']='NOT_YET_HISTORICAL';return result
        if gate.read()!=(None,None) or audit.read()!=(None,None):raise ValueError('independent_dry/consumed')
        old=(legacy_gate.read(),legacy_audit.read(),legacy_original.read())
        command=attest();binding=binding_type(session,native)
        proof=preflight(store,session,native,private_evidence=True)
        if not isinstance(proof,IndependentCaptureEvidence) or not binding():raise ValueError('independent_dry/preflight')
        saved=deepcopy(binding._saved);grant=deepcopy(binding._grant)
        if saved['vid']!=plan['owner'] or grant['vid']!=plan['owner']:raise ValueError('independent_dry/session')
        report,*_=proof.for_bundle(bundle,grant)
        def fresh():
            return (binding() is True and store.read()==(bundle,receipt) and gate.read()==(None,None)
                    and audit.read()==(None,None) and (legacy_gate.read(),legacy_audit.read(),legacy_original.read())==old)
        if not fresh() or not 0<=int(clock())-report['completed_at']<30:raise ValueError('independent_dry/stale')
        inputs=signer(grant,binding).read()
        if not isinstance(inputs,SigningInputs) or not fresh() or not 0<=int(clock())-report['completed_at']<30:
            raise ValueError('independent_dry/stale')
        prepared=Prepared(deepcopy(bundle),receipt,deepcopy(grant),proof)
        result['dispatch_may_have_occurred']=True;result['account_data_posts']=None
        checked=broker(prepared,inputs,saved['cookies'],store,gate,audit,binding,command,armed=False)
        result['dispatch_may_have_occurred']=checked.get('dispatch_may_have_occurred') is not False
        if not result['dispatch_may_have_occurred']:result['account_data_posts']=0
        if (checked.get('result')!='INDEPENDENT_NATIVE_DRY_RUN_VERIFIED' or checked.get('profile_removed') is not True
                or checked.get('dispatch_may_have_occurred') is not False or checked.get('account_data_posts_confirmed')!=0
                or checked.get('authentication_posts')!=0 or not fresh()):raise ValueError('independent_dry/result')
        result.update(result='INDEPENDENT_NATIVE_DRY_RUN_VERIFIED',profile_removed=True,
                      capture_and_all_journals_unchanged=True)
    except (Exception,KeyboardInterrupt) as error:
        if isinstance(error,ValueError) and re.fullmatch(r'independent_dry/[a-z_]+',str(error)):result['reason']=str(error)
    finally:
        if prepared:prepared.close()
        if binding:binding.close()
        for name in ('saved','grant'):
            value=locals().get(name)
            if isinstance(value,dict):value.clear()
    return result


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-capture',action='store_true');args=parser.parse_args(argv)
    if not args.saved_capture:
        print(json.dumps(dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    try:
        result=run(capture_store(),SessionStore(),NativeSessionStore(),IndependentGate(),IndependentAudit(),
                   DispatchGate(),FreshAuditStore(),LegacyAudit())
    except (Exception,KeyboardInterrupt):result=dict(result='UNVERIFIED',account_data_posts=0,authentication_posts=0)
    print(json.dumps(result));return int(result['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
