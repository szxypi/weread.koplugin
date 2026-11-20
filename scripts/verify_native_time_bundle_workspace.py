#!/usr/bin/env python3
"""Offline-by-default inspection of a saved capture in a private runtime."""
import argparse
import json
import resource
import subprocess
import time

from native_time_bundle_audit_store import AuditStore
from native_time_bundle_gate import DispatchGate
from native_time_capture_bundle import CaptureBundleStore,MAX_BYTES
from native_trial_pipe import stop
from run_native_time_bundle_inspect import validate_input


def inspect(store,gate,audit,command):
    if not isinstance(command,list) or not command or any(not isinstance(part,str) or not part for part in command):
        raise ValueError('bundle_workspace/command')
    bundle,receipt=store.read();gate_before=gate.read();audit_before=audit.read()
    if bundle is None or receipt is None:raise ValueError('bundle_workspace/capture')
    validate_input(bundle,time.time())
    payload=json.dumps(bundle,separators=(',',':')).encode()
    if len(payload)>MAX_BYTES:raise ValueError('bundle_workspace/size')
    child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
    try:
        out,_=child.communicate(payload,timeout=120)
        if child.returncode or len(out)>65536:raise ValueError('bundle_workspace/runner')
        value=json.loads(out)
    finally:stop(child)
    flags=('exact_rows','archive_verified','coverage_verified','same_day_deferred','pending_unchanged','profile_removed')
    if (not isinstance(value,dict) or set(value)!=set(flags)|{'result','seconds','account_data_posts','authentication_posts'}
            or value['result']!='SAME_DAY_DEFERRED' or value['seconds']!=bundle['plan']['seconds']
            or any(value[key] is not True for key in flags)
            or any(type(value[key]) is not int or value[key]!=0 for key in ('account_data_posts','authentication_posts'))
            or store.read()!=(bundle,receipt) or gate.read()!=gate_before or audit.read()!=audit_before):
        raise ValueError('bundle_workspace/result')
    return {'result':'SAME_DAY_DEFERRED','exact_rows':True,'archive_verified':True,'coverage_verified':True,
            'pending_unchanged':True,'profile_removed':True,'saved_scopes_unchanged':True,
            'account_data_posts':0,'authentication_posts':0}


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--native-command',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    if bool(args.saved_session)!=bool(args.native_command):parser.error('saved session and native command required together')
    result={'result':'OFFLINE_ONLY','account_data_posts':0,'authentication_posts':0}
    try:
        if args.saved_session:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0))
            result=inspect(CaptureBundleStore(),DispatchGate(),AuditStore(),args.native_command)
    except (Exception,KeyboardInterrupt):result['result']='UNVERIFIED'
    print(json.dumps(result));return int(result['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
