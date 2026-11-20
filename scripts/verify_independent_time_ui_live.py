#!/usr/bin/env python3
"""One guarded native-menu transfer followed by independent read-only checks.

The separate durable journal never permits replay of a consumed capture.
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
from native_time_bundle_preparation import SigningInputs,SigningRead
from native_time_capture_fresh_bundle import store as capture_store
from native_time_independent_audit import IndependentAudit
from native_time_independent_broker import AccountBinding,Prepared,execute as broker_execute,ui_live_command_from
from native_time_independent_gate import IndependentGate
from native_time_independent_readback import run as readback_run
from secure_native_session import NativeSessionStore
from secure_weread_session import MacKeychain,SessionStore
from verify_fresh_time_capture_readonly import run as preflight_run
from verify_independent_time_dry import run as dry_run
from verify_native_time_fresh_dry import trusted_command


def trusted_ui_live_command():
    return ui_live_command_from(trusted_command())


def run(store,session,native,gate,audit,legacy_gate,legacy_audit,legacy_original,*,clock=time.time,
        attest=trusted_ui_live_command,rehearsal=dry_run,preflight=preflight_run,signer=SigningRead,
        broker=broker_execute,readback=readback_run,binding_type=AccountBinding):
    result=dict(result='UNVERIFIED',account_data_posts=0,authentication_posts=0,dispatch_may_have_occurred=False,
                independent_readback=False,real_accounting_verified=False,private_data_in_report=False)
    binding=prepared=None;attempted=False
    try:
        real=any(isinstance(getattr(item,'backend',None),MacKeychain) for item in
                 (store,gate,audit,legacy_gate,legacy_audit,legacy_original))
        if real and (clock is not time.time or attest is not trusted_ui_live_command or rehearsal is not dry_run
                or preflight is not preflight_run or signer is not SigningRead or broker is not broker_execute
                or readback is not readback_run or binding_type is not AccountBinding
                or type(session) is not SessionStore or type(native) is not NativeSessionStore):
            raise ValueError('independent_live/override')
        bundle,receipt=store.read()
        if not bundle or receipt is None:raise ValueError('independent_live/capture')
        plan=bundle['plan'];now=int(clock())
        if now<plan['not_before'] or day(now)<=day(plan['start_time']):
            result['result']='NOT_YET_HISTORICAL';return result
        if gate.read()!=(None,None) or audit.read()!=(None,None):raise ValueError('independent_live/consumed')
        old=(legacy_gate.read(),legacy_audit.read(),legacy_original.read())
        result.update(dispatch_may_have_occurred=True,account_data_posts=None)
        dry=rehearsal(store,session,native,gate,audit,legacy_gate,legacy_audit,legacy_original,ui=True,live_worker=True)
        if dry.get('dispatch_may_have_occurred') is False and dry.get('account_data_posts')==0:
            result.update(dispatch_may_have_occurred=False,account_data_posts=0)
        if (dry.get('result')!='INDEPENDENT_NATIVE_MENU_DRY_VERIFIED' or dry.get('profile_removed') is not True
                or dry.get('dispatch_may_have_occurred') is not False or dry.get('account_data_posts')!=0
                or dry.get('authentication_posts')!=0 or dry.get('capture_and_all_journals_unchanged') is not True):
            raise ValueError('independent_live/rehearsal')
        def unconsumed():
            return (store.read()==(bundle,receipt) and gate.read()==(None,None) and audit.read()==(None,None)
                    and (legacy_gate.read(),legacy_audit.read(),legacy_original.read())==old)
        if not unconsumed():raise ValueError('independent_live/consumed')
        command=attest();binding=binding_type(session,native)
        proof=preflight(store,session,native,private_evidence=True)
        if not isinstance(proof,IndependentCaptureEvidence) or binding() is not True:raise ValueError('independent_live/preflight')
        saved=deepcopy(binding._saved);grant=deepcopy(binding._grant)
        if saved['vid']!=plan['owner'] or grant['vid']!=plan['owner']:raise ValueError('independent_live/session')
        report,*_=proof.for_bundle(bundle,grant)
        def fresh():return binding() is True and unconsumed() and 0<=int(clock())-report['completed_at']<30
        if not fresh():raise ValueError('independent_live/stale')
        inputs=signer(grant,binding).read()
        if not isinstance(inputs,SigningInputs) or not fresh():raise ValueError('independent_live/stale')
        prepared=Prepared(deepcopy(bundle),receipt,deepcopy(grant),proof)
        attempted=True;result.update(dispatch_may_have_occurred=True,account_data_posts=None)
        sent=broker(prepared,inputs,saved['cookies'],store,gate,audit,binding,command,armed=True)
        if sent.get('dispatch_may_have_occurred') is False:
            result.update(dispatch_may_have_occurred=False,account_data_posts=0)
            raise ValueError('independent_live/not_dispatched')
        packet,audit_receipt,state,gate_receipt=audit.inspect(bundle,grant,gate)
        if state['phase']!='acknowledged' or audit_receipt is None or gate_receipt is None:
            raise ValueError('independent_live/unconfirmed')
        menu_confirmed=(sent.get('result')=='INDEPENDENT_NATIVE_ACKNOWLEDGED' and sent.get('profile_removed') is True
                        and sent.get('account_data_posts_confirmed')==1 and sent.get('authentication_posts')==0)
        result.update(result='INDEPENDENT_MENU_ACKNOWLEDGED_READBACK_UNVERIFIED',account_data_posts=1,
                      menu_confirmed=menu_confirmed)
        checked=readback(saved=saved,grant=grant,store=store,gate=gate,audit=audit,current=binding)
        if (checked.get('result')=='READBACK_PARTIAL' and checked.get('independent_samples')==3
                and checked.get('accounting_and_core_state_exact') is True and checked.get('full_shelf_exact') is False
                and checked.get('account_data_posts')==0 and checked.get('authentication_posts')==0):
            result.update(accounting_and_core_state_observed=True,full_shelf_exact=False)
            if checked.get('component_diagnosis_available') is True:
                result.update(component_diagnosis_available=True,native_shelf_change=checked['native_shelf_change'],
                              web_shelf_change=checked['web_shelf_change'])
        if (checked.get('result')!='READBACK_MATCH' or checked.get('independent_samples')!=3
                or checked.get('other_state_exact') is not True or checked.get('full_shelf_exact') is not True
                or checked.get('account_data_posts')!=0 or checked.get('authentication_posts')!=0
                or store.read()!=(bundle,receipt) or gate.read()!=(state,gate_receipt)
                or audit.read()[1]!=audit_receipt or (legacy_gate.read(),legacy_audit.read(),legacy_original.read())!=old
                or binding() is not True):raise ValueError('independent_live/readback')
        result.update(result='INDEPENDENT_MENU_READBACK_MATCH' if menu_confirmed else 'INDEPENDENT_READBACK_MATCH_MENU_UNVERIFIED',
                      independent_readback=True,historical_date_matched=True,real_accounting_verified=real,seconds=plan['seconds'])
    except (Exception,KeyboardInterrupt) as error:
        if isinstance(error,ValueError) and re.fullmatch(r'independent_live/[a-z_]+',str(error)):result['reason']=str(error)
        if attempted and result['account_data_posts']==0 and result['dispatch_may_have_occurred'] is not False:
            result['account_data_posts']=None
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
    except (Exception,KeyboardInterrupt):
        result=dict(result='UNVERIFIED',account_data_posts=None,dispatch_may_have_occurred=True,authentication_posts=0)
    print(json.dumps(result));return int(result['result'] not in ('NOT_YET_HISTORICAL','INDEPENDENT_MENU_READBACK_MATCH'))


if __name__=='__main__':raise SystemExit(main())
