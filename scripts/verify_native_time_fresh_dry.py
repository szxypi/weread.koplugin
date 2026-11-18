#!/usr/bin/env python3
"""Saved ordinary-book native rehearsal; no time upload or authorization renewal."""
import argparse
from copy import deepcopy
import json
import re
import resource
import time

from native_time_bundle_audit_store import AuditStore as LegacyAuditStore
from native_time_bundle_fresh_audit import FreshAuditStore
from native_time_bundle_fresh_broker import Prepared,execute as broker_execute
from native_time_bundle_gate import DispatchGate,day
from native_time_bundle_preparation import SigningRead,read_fresh_evidenced_signing_inputs
from native_time_bundle_trial_scope import LiveTrialReader
from native_time_capture_bundle import CaptureBundleStore
from secure_native_session import NativeSessionStore
from secure_weread_session import MacKeychain,SessionStore
from verify_cb_native_time_guarded_dry import trusted_command as cb_trusted_command
from verify_native_time_capture import XhtmlSource
from verify_native_time_cross_day import run as cross_day_preflight
from verify_translation_preflight import save_refreshed_web_session


def trusted_command():
    command=cb_trusted_command();old='scripts/run_cb_native_time_guarded_dry.py'
    if command.count(old)!=1:raise ValueError('fresh_dry/container')
    command[command.index(old)]='scripts/run_native_time_guarded_worker.py'
    return command


def run(store,session,native,gate,audit,legacy_audit,*,clock=time.time,attest=trusted_command,
        preflight=cross_day_preflight,web_factory=XhtmlSource,signer=SigningRead,broker=broker_execute,
        trial_factory=LiveTrialReader,save_web=save_refreshed_web_session):
    result=dict(result='UNVERIFIED',account_data_posts=0,authentication_posts=0,dispatch_may_have_occurred=False,
                real_accounting_verified=False,private_data_in_report=False)
    prepared=saved=grant=web=None
    try:
        real=any(isinstance(getattr(item,'backend',None),MacKeychain) for item in (store,gate,audit,legacy_audit))
        if real and (clock is not time.time or attest is not trusted_command or preflight is not cross_day_preflight
                or web_factory is not XhtmlSource or signer is not SigningRead or broker is not broker_execute
                or trial_factory is not LiveTrialReader or save_web is not save_refreshed_web_session
                or type(session) is not SessionStore or type(native) is not NativeSessionStore):
            raise ValueError('fresh_dry/override')
        bundle,receipt=store.read()
        if not bundle or receipt is None:raise ValueError('fresh_dry/capture')
        plan=bundle['plan'];now=int(clock())
        if now<plan['not_before'] or day(now)<=day(plan['start_time']):
            result['result']='NOT_YET_HISTORICAL';return result
        if gate.read()!=(None,None) or audit.read()!=(None,None) or legacy_audit.read()!=(None,None):
            raise ValueError('fresh_dry/consumed')
        command=attest()
        saved=session.load();grant=native.load(saved['vid'])
        if saved['vid']!=plan['owner'] or grant['vid']!=plan['owner']:raise ValueError('fresh_dry/session')
        def current():return session.load()==saved and native.load(saved['vid'])==grant
        web=web_factory();web.vid=saved['vid']
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        evidence=preflight(saved,grant,store,current,web,baseline_includes_fixture=True,fresh_shelf=True,private_evidence=True)
        if save_web(session,saved,web):
            newer=session.load()
            if newer['vid']!=plan['owner']:raise ValueError('fresh_dry/session')
            saved.clear();saved=newer
        if not current() or store.read()!=(bundle,receipt) or gate.read()!=(None,None) or audit.read()!=(None,None):
            raise ValueError('fresh_dry/stale')
        trial=trial_factory(bundle,current)
        prepared=Prepared(deepcopy(bundle),receipt,deepcopy(grant),evidence)
        inputs=read_fresh_evidenced_signing_inputs(bundle=prepared.bundle,receipt=receipt,grant=prepared.grant,store=store,
                   gate=gate,current=current,evidence=evidence,trial_reader=trial,probe=signer(grant,current),clock=clock)
        result['dispatch_may_have_occurred']=True;result['account_data_posts']=None
        checked=broker(prepared,inputs,saved['cookies'],store,gate,audit,current,trial,command,armed=False)
        result['dispatch_may_have_occurred']=checked.get('dispatch_may_have_occurred') is not False
        if not result['dispatch_may_have_occurred']:result['account_data_posts']=0
        if (checked.get('result')!='NATIVE_FRESH_DRY_RUN_VERIFIED' or checked.get('profile_removed') is not True
                or checked.get('dispatch_may_have_occurred') is not False or checked.get('account_data_posts_confirmed')!=0
                or checked.get('authentication_posts')!=0 or store.read()!=(bundle,receipt) or gate.read()!=(None,None)
                or audit.read()!=(None,None) or legacy_audit.read()!=(None,None) or not current()):
            raise ValueError('fresh_dry/result')
        result.update(result='NATIVE_FRESH_DRY_RUN_VERIFIED',profile_removed=True,capture_and_journals_unchanged=True)
    except (Exception,KeyboardInterrupt) as error:
        if isinstance(error,ValueError) and re.fullmatch(r'fresh_dry/[a-z_]+',str(error)):result['reason']=str(error)
    finally:
        if web:
            web.shards.clear()
            if hasattr(web,'_time_catalog_pair'):web._time_catalog_pair.clear()
            web.close()
        if prepared:prepared.close()
        for value in (saved,grant):
            if isinstance(value,dict):value.clear()
    return result


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-capture',action='store_true');args=parser.parse_args(argv)
    if not args.saved_capture:
        print(json.dumps(dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    try:result=run(CaptureBundleStore(),SessionStore(),NativeSessionStore(),DispatchGate(),FreshAuditStore(),LegacyAuditStore())
    except (Exception,KeyboardInterrupt):result=dict(result='UNVERIFIED',account_data_posts=0,authentication_posts=0)
    print(json.dumps(result));return int(result['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
