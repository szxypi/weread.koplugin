#!/usr/bin/env python3
"""Inspect a saved bundle with the native queue, offline and on the real clock."""
import argparse
import json
import os
from pathlib import Path
import resource
import sys
import tempfile
import time

from native_time_capture_evidence import validate_evidence
from native_time_capture_bundle import MAX_BYTES
from native_time_bundle_workspace import restore
from run_persistent_ui_probe import extract_candidate, run_child

FRAME=b'\nWEREAD_NATIVE_BUNDLE_INSPECT_RESULT='


def validate_input(bundle,now,*,imported=False):
    if not isinstance(bundle,dict) or set(bundle)!={'plan','evidence'}:raise ValueError('bundle_inspect/input')
    plan=bundle['plan'];validate_evidence(plan,bundle['evidence'],imported=imported)
    if not plan['ended_at']<=now<plan['not_before']:raise ValueError('bundle_inspect/not_same_day')
    return bundle


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader',required=True,type=Path);parser.add_argument('--candidate',required=True,type=Path)
    parser.add_argument('--cb-reading',action='store_true')
    args=parser.parse_args(argv);runtime=args.koreader.resolve()
    if (sys.platform!='linux' or not (runtime/'luajit').is_file()
            or not any(line.split()[1:3]==['/dev/shm','tmpfs'] for line in Path('/proc/mounts').read_text().splitlines())):
        parser.error('Linux KOReader and tmpfs required')
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    result={'result':'UNVERIFIED','profile_removed':False,'account_data_posts':0,'authentication_posts':0}
    root=None
    try:
        raw=sys.stdin.buffer.read(MAX_BYTES+1)
        if len(raw)>MAX_BYTES:raise ValueError('bundle_inspect/input')
        bundle=validate_input(json.loads(raw),time.time(),imported=args.cb_reading);plan=bundle['plan']
        with tempfile.TemporaryDirectory(prefix='weread-bundle-inspect-',dir='/dev/shm') as directory:
            root=Path(directory);profile=root/'profile';plugins=profile/'plugins';plugins.mkdir(parents=True)
            extract_candidate(args.candidate,plugins)
            epub,ledger=restore(bundle,root,imported=args.cb_reading)
            private={key:value for key,value in plan.items() if key!='archive_base64'}
            env=dict(os.environ,KO_HOME=str(profile),TZ='Asia/Shanghai',LD_LIBRARY_PATH=str(runtime/'libs'),
                     EMULATE_READER='1',EMULATE_BW_SCREEN='1',EMULATE_BB_TYPE='BB8')
            probe=Path(__file__).resolve().parent.parent/'spec/koreader/native_time_bundle_inspect.lua'
            command=[str(runtime/'luajit'),str(probe),str(plugins/'weread.koplugin'),str(ledger),str(epub)]
            if args.cb_reading:command.append('cb')
            code,out,repaint=run_child(command,env,json.dumps(private,separators=(',',':')).encode(),runtime,timeout=60)
            if code or repaint or out.count(FRAME)!=1:raise ValueError('bundle_inspect/native')
            value=json.loads(out.split(FRAME)[1])
            flags=('exact_rows','archive_verified','coverage_verified','same_day_deferred','pending_unchanged')
            if (not isinstance(value,dict) or set(value)!=set(flags)|{'result','seconds','account_data_posts','authentication_posts'}
                    or value['result']!='SAME_DAY_DEFERRED' or value['seconds']!=plan['seconds']
                    or any(value[k] is not True for k in flags)
                    or any(type(value[k]) is not int or value[k]!=0 for k in ('account_data_posts','authentication_posts'))):
                raise ValueError('bundle_inspect/result')
            result.update(value)
    except Exception:
        result['result']='UNVERIFIED'
    finally:
        result['profile_removed']=root is not None and not root.exists()
    print(json.dumps(result))
    return int(result['result']!='SAME_DAY_DEFERRED' or not result['profile_removed'])


if __name__=='__main__':raise SystemExit(main())
