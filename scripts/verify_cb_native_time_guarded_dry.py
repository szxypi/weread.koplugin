#!/usr/bin/env python3
"""Bound saved-account CB native dry run; no time upload or auth renewal."""
import argparse,json,re,resource,shutil,subprocess,time
from pathlib import Path

from cb_native_time_bundle_audit_store import AuditStore
from cb_native_time_bundle_broker import execute as broker_execute
from cb_native_time_bundle_gate import DispatchGate,day
from cb_native_time_bundle_preflight import run as preflight_run
from cb_native_time_bundle_preparation import read_inputs
from cb_native_time_capture_bundle import store as capture_store
from secure_native_session import NativeSessionStore
from secure_weread_session import MacKeychain,SessionStore


def trusted_command():
    """Use only the known local container, source mount and matching candidate."""
    docker=shutil.which('docker')
    if not docker:raise ValueError('cb_dry/container')
    source=Path(__file__).resolve().parent.parent;validation=(source.parent/'.validation').resolve(strict=True)
    query=subprocess.run([docker,'inspect','--format','{{json .State.Running}} {{json .Id}} {{json .Mounts}}','weread-validation'],
                         stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=15,check=True)
    if len(query.stdout)>65536:raise ValueError('cb_dry/container')
    running,identifier,mounts=query.stdout.decode().strip().split(' ',2)
    running,identifier,mounts=json.loads(running),json.loads(identifier),json.loads(mounts)
    if running is not True or not isinstance(identifier,str) or not re.fullmatch('[a-f0-9]{64}',identifier):raise ValueError('cb_dry/container')
    wanted={'/source':(source.resolve(),False),'/validation':(validation,True)}
    for destination,(expected,writable) in wanted.items():
        matches=[item for item in mounts if item.get('Destination')==destination]
        if (len(matches)!=1 or matches[0].get('Type')!='bind' or Path(matches[0].get('Source','')).resolve()!=expected
                or matches[0].get('RW') is not writable):raise ValueError('cb_dry/container')
    prefix=[docker,'exec','-i','-w','/source',identifier]
    checked=subprocess.run(prefix+['python3','scripts/build_cb_dry_candidate.py','--source','/source',
                                    '--directory','/validation'],
                           stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=30,check=True)
    value=json.loads(checked.stdout)
    if (not isinstance(value,dict) or set(value)!={'result','files','path'} or value['result']!='CANDIDATE_READY'
            or type(value['files']) is not int or value['files']<1 or not isinstance(value['path'],str)
            or not re.fullmatch(r'/validation/cb-dry-candidate-[a-f0-9]{64}\.zip',value['path'])):
        raise ValueError('cb_dry/candidate')
    return prefix+['python3','scripts/run_cb_native_time_guarded_dry.py','--koreader','/validation/runtime/lib/koreader',
                   '--source','/source','--candidate',value['path']]


def run(store,session,native,gate,audit,*,clock=time.time,attest=trusted_command,preflight=preflight_run,
        prepare=read_inputs,broker=broker_execute):
    result=dict(result='UNVERIFIED',account_data_posts=0,authentication_posts=0,dispatch_may_have_occurred=False,
                real_accounting_verified=False,private_data_in_report=False)
    prepared=saved=grant=None
    try:
        real=any(isinstance(getattr(item,'backend',None),MacKeychain) for item in (store,gate,audit))
        if real and (clock is not time.time or attest is not trusted_command or preflight is not preflight_run
                     or prepare is not read_inputs or broker is not broker_execute):raise ValueError('cb_dry/override')
        bundle,receipt=store.read()
        if not bundle or receipt is None:raise ValueError('cb_dry/capture')
        plan=bundle['plan'];now=int(clock())
        if now<plan['not_before'] or day(now)<=day(plan['start_time']):
            result['result']='NOT_YET_HISTORICAL';return result
        command=attest()
        report,prepared=preflight(store,session,native,gate,audit)
        if report.get('result')!='CB_CROSS_DAY_READONLY_VERIFIED' or prepared is None:raise ValueError('cb_dry/preflight')
        if store.read()!=(bundle,receipt) or prepared.receipt!=receipt or prepared.bundle!=bundle:raise ValueError('cb_dry/capture')
        saved=session.load();grant=native.load(saved['vid'])
        if saved['vid']!=plan['owner'] or grant!=prepared.grant:raise ValueError('cb_dry/session')
        def current():return session.load()==saved and native.load(saved['vid'])==grant
        inputs=prepare(prepared,store,gate,audit,current)
        result['dispatch_may_have_occurred']=True;result['account_data_posts']=None
        checked=broker(prepared,inputs,saved['cookies'],store,gate,audit,current,command,armed=False)
        result['dispatch_may_have_occurred']=checked.get('dispatch_may_have_occurred') is not False
        if not result['dispatch_may_have_occurred']:result['account_data_posts']=0
        if (checked.get('result')!='CB_NATIVE_DRY_RUN_VERIFIED' or checked.get('profile_removed') is not True
                or checked.get('dispatch_may_have_occurred') is not False
                or checked.get('account_data_posts_confirmed')!=0 or checked.get('authentication_posts')!=0
                or store.read()!=(bundle,receipt) or gate.read()!=(None,None) or audit.read()!=(None,None) or not current()):
            raise ValueError('cb_dry/result')
        result.update(result='CB_NATIVE_DRY_RUN_VERIFIED',profile_removed=True,capture_and_journals_unchanged=True)
    except Exception as error:
        if isinstance(error,ValueError) and re.fullmatch(r'cb_dry/[a-z_]+',str(error)):result['reason']=str(error)
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
    except (Exception,KeyboardInterrupt):result=dict(result='UNVERIFIED',account_data_posts=0,authentication_posts=0)
    print(json.dumps(result));return int(result['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
