#!/usr/bin/env python3
"""Inspect only the dedicated imported-book capture; no claim or network."""
import argparse,json,resource,subprocess,time

from cb_native_time_capture_bundle import store as capture_store
from native_time_capture_bundle import MAX_BYTES
from native_trial_pipe import stop
from run_native_time_bundle_inspect import validate_input


def inspect(store,command,clock=time.time):
    if not isinstance(command,list) or not command or any(not isinstance(item,str) or not item for item in command):
        raise ValueError('cb_capture_inspect/command')
    bundle,receipt=store.read()
    if bundle is None or receipt is None:raise ValueError('cb_capture_inspect/missing')
    validate_input(bundle,clock(),imported=True)
    payload=json.dumps(bundle,separators=(',',':')).encode()
    if len(payload)>MAX_BYTES:raise ValueError('cb_capture_inspect/size')
    child=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,start_new_session=True)
    try:
        output,_=child.communicate(payload,timeout=120)
        if child.returncode or len(output)>65536:raise ValueError('cb_capture_inspect/runner')
        value=json.loads(output)
    finally:stop(child)
    flags=('exact_rows','archive_verified','coverage_verified','same_day_deferred','pending_unchanged','profile_removed')
    if (not isinstance(value,dict) or set(value)!=set(flags)|{'result','seconds','account_data_posts','authentication_posts'}
            or value['result']!='SAME_DAY_DEFERRED' or value['seconds']!=bundle['plan']['seconds']
            or any(value[key] is not True for key in flags)
            or any(type(value[key]) is not int or value[key]!=0 for key in ('account_data_posts','authentication_posts'))
            or store.read()!=(bundle,receipt)):raise ValueError('cb_capture_inspect/result')
    return dict(result='SAME_DAY_DEFERRED',seconds=value['seconds'],exact_rows=True,archive_verified=True,
                coverage_verified=True,pending_unchanged=True,profile_removed=True,saved_capture_unchanged=True,
                account_data_posts=0,authentication_posts=0)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-capture',action='store_true')
    parser.add_argument('--native-command',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    if bool(args.saved_capture)!=bool(args.native_command):parser.error('saved capture and native command required together')
    result=dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0)
    if args.saved_capture:
        try:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0));result=inspect(capture_store(),args.native_command)
        except Exception:result['result']='UNVERIFIED'
    print(json.dumps(result));return int(result['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
