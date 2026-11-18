#!/usr/bin/env python3
"""One-shot saved-account CB transfer after an independent no-upload rehearsal."""
import argparse,json,re,resource,time

from cb_native_time_bundle_audit_store import AuditStore
from cb_native_time_bundle_broker import execute as broker_execute
from cb_native_time_bundle_gate import DispatchGate,day
from cb_native_time_bundle_preflight import run as preflight_run
from cb_native_time_bundle_preparation import read_inputs
from cb_native_time_bundle_readback import run as readback_run
from cb_native_time_capture_bundle import store as capture_store
from secure_native_session import NativeSessionStore
from secure_weread_session import MacKeychain,SessionStore
from verify_cb_native_time_guarded_dry import run as dry_run, trusted_command


def trusted_live_command():
    """Reuse mount and candidate attestation; only switch the worker entry."""
    command=trusted_command()
    worker='scripts/run_cb_native_time_guarded_dry.py'
    if command.count(worker)!=1:raise ValueError('cb_live/container')
    command[command.index(worker)]='scripts/run_cb_native_time_guarded_live.py'
    return command


def run(store,session,native,gate,audit,*,clock=time.time,attest=trusted_live_command,
        rehearsal=dry_run,preflight=preflight_run,prepare=read_inputs,broker=broker_execute,readback=readback_run):
    result=dict(result='UNVERIFIED',account_data_posts=0,authentication_posts=0,
                dispatch_may_have_occurred=False,independent_readback=False,private_data_in_report=False)
    prepared=saved=grant=None
    try:
        real=any(isinstance(getattr(item,'backend',None),MacKeychain) for item in (store,gate,audit))
        if real and (clock is not time.time or attest is not trusted_live_command or rehearsal is not dry_run
                     or preflight is not preflight_run or prepare is not read_inputs or broker is not broker_execute
                     or readback is not readback_run or type(session) is not SessionStore or type(native) is not NativeSessionStore):
            raise ValueError('cb_live/override')
        bundle,receipt=store.read()
        if not bundle or receipt is None:raise ValueError('cb_live/capture')
        plan=bundle['plan'];now=int(clock())
        if now<plan['not_before'] or day(now)<=day(plan['start_time']):
            result['result']='NOT_YET_HISTORICAL';return result
        if gate.read()!=(None,None) or audit.read()!=(None,None):raise ValueError('cb_live/consumed')
        result['dispatch_may_have_occurred']=True;result['account_data_posts']=None
        dry=rehearsal(store,session,native,gate,audit)
        if dry.get('dispatch_may_have_occurred') is False and dry.get('account_data_posts')==0:
            result['dispatch_may_have_occurred']=False;result['account_data_posts']=0
        if (dry.get('result')!='CB_NATIVE_DRY_RUN_VERIFIED' or dry.get('profile_removed') is not True
                or dry.get('dispatch_may_have_occurred') is not False or dry.get('account_data_posts')!=0
                or dry.get('authentication_posts')!=0 or dry.get('capture_and_journals_unchanged') is not True):
            raise ValueError('cb_live/rehearsal')
        if store.read()!=(bundle,receipt) or gate.read()!=(None,None) or audit.read()!=(None,None):raise ValueError('cb_live/capture')
        command=attest()
        report,prepared=preflight(store,session,native,gate,audit)
        if report.get('result')!='CB_CROSS_DAY_READONLY_VERIFIED' or prepared is None:raise ValueError('cb_live/preflight')
        if store.read()!=(bundle,receipt) or prepared.receipt!=receipt or prepared.bundle!=bundle:raise ValueError('cb_live/capture')
        saved=session.load();grant=native.load(saved['vid'])
        if saved['vid']!=plan['owner'] or grant!=prepared.grant:raise ValueError('cb_live/session')
        def current():return session.load()==saved and native.load(saved['vid'])==grant
        inputs=prepare(prepared,store,gate,audit,current)
        # A lost broker response can follow a real request; conservatively mark
        # it ambiguous before handing over control and never retry here.
        result['dispatch_may_have_occurred']=True;result['account_data_posts']=None
        sent=broker(prepared,inputs,saved['cookies'],store,gate,audit,current,command,armed=True)
        if sent.get('dispatch_may_have_occurred') is False:
            result['dispatch_may_have_occurred']=False;result['account_data_posts']=0
        if (sent.get('result')!='CB_NATIVE_ACKNOWLEDGED' or sent.get('dispatch_may_have_occurred') is not True
                or sent.get('profile_removed') is not True or sent.get('account_data_posts_confirmed')!=1
                or sent.get('authentication_posts')!=0):raise ValueError('cb_live/dispatch')
        result['account_data_posts']=1;result['result']='CB_NATIVE_ACKNOWLEDGED_READBACK_UNVERIFIED'
        checked=readback(session,native,store,gate,audit)
        if (checked.get('result')!='CB_READBACK_MATCH' or checked.get('independent_samples')!=3
                or checked.get('historical_date_matched') is not True
                or checked.get('positions_source_shelves_and_other_counts_unchanged') is not True
                or checked.get('account_data_posts')!=0 or checked.get('authentication_posts')!=0
                or type(checked.get('seconds')) is not int or checked['seconds']!=plan['seconds']):
            raise ValueError('cb_live/readback')
        result.update(result='CB_NATIVE_TRANSFER_READBACK_MATCH',independent_readback=True,
                      historical_date_matched=True,seconds=checked['seconds'])
    except (Exception,KeyboardInterrupt) as error:
        if isinstance(error,ValueError) and re.fullmatch(r'cb_live/[a-z_]+',str(error)):result['reason']=str(error)
    finally:
        if prepared:prepared.close()
        for value in (saved,grant):
            if isinstance(value,dict):value.clear()
    return result


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-capture',action='store_true');args=parser.parse_args(argv)
    if not args.saved_capture:
        print(json.dumps(dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    try:result=run(capture_store(),SessionStore(),NativeSessionStore(),DispatchGate(),AuditStore())
    except (Exception,KeyboardInterrupt):result=dict(result='UNVERIFIED',account_data_posts=None,dispatch_may_have_occurred=True)
    print(json.dumps(result));return int(result['result'] not in ('NOT_YET_HISTORICAL','CB_NATIVE_TRANSFER_READBACK_MATCH'))


if __name__=='__main__':raise SystemExit(main())
