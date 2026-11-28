#!/usr/bin/env python3
"""Synthetic native accounting parity for a six-second captured window."""
import argparse,json,subprocess
from copy import deepcopy

from native_time_bundle_accounting import audit,day
from test_native_time_bundle_accounting import example
from verify_native_statistics import period


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv);report={'result':'OFFLINE_ONLY','synthetic_only':True,'account_data_posts':0,'authentication_posts':0}
    mode='setup'
    try:
        if args.lua_command:
            checked=0
            for mode in ('target','zero_removed','before','lagging','other_count','other_month'):
                capture,grant,before,samples,now=example(cross_month=True);p=capture['plan']
                old=str(period('monthly',p['start_time'])[0])
                current=str(period('monthly',now)[0])
                for sample in samples:
                    if mode=='zero_removed':del sample['months'][old]['readTimes'][old]
                    elif mode=='before':sample['snapshot']=deepcopy(before['snapshot']);sample['months']=deepcopy(before['months'])
                    elif mode=='lagging':sample['months']=deepcopy(before['months'])
                    elif mode=='other_count':sample['snapshot']['counts']['ttsTime']+=1
                    elif mode=='other_month':sample['months'][current]['totalReadTime']+=1
                try:result=audit(capture,grant,before,samples,now)
                except ValueError:result=None
                metadata=dict(seconds=p['seconds'],day=day(p['start_time']),counts=before['snapshot']['counts'],months=before['months'])
                payload=dict(synthetic=True,metadata=metadata,counts=samples[0]['snapshot']['counts'],months=samples[0]['months'])
                child=subprocess.run(args.lua_command,input=json.dumps(payload).encode(),stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=30)
                if child.returncode or len(child.stdout)>65536:raise ValueError('accounting_probe/lua')
                frame=b'\nWEREAD_BUNDLE_ACCOUNTING='
                if child.stdout.count(frame)!=1:raise ValueError('accounting_probe/lua')
                native=json.loads(child.stdout.split(frame)[1])['result']
                if mode in ('target','zero_removed'):
                    if not result or not isinstance(native,dict) or native.get('kind')!='target' or native.get('removed_zero_buckets')!=result['removed_zero_buckets']:
                        raise ValueError('accounting_probe/mismatch')
                elif result is not None or (native is not False and native.get('kind') not in ('before','lagging')):
                    raise ValueError('accounting_probe/mismatch')
                checked+=1
            report.update(result='SYNTHETIC_NATIVE_ACCOUNTING_PARITY',cases=checked,cross_month=True,
                          zero_bucket_rule_matches=True,historical_accounting_verified=False)
    except Exception as error:
        report['result']='UNVERIFIED';report['synthetic_failure_mode']=mode;report['synthetic_failure_type']=type(error).__name__
        if str(error) in ('accounting_probe/lua','accounting_probe/mismatch'):report['synthetic_failure_reason']=str(error)
    print(json.dumps(report));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
