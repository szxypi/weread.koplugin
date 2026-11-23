#!/usr/bin/env python3
"""Read-only recovery of a previously acknowledged direct time trial."""
import json
import resource
import subprocess
import time
from native_direct_time_trial_store import Intent
from native_time_capture_evidence import account_key
from native_direct_time_trial_contract import day
from verify_native_statistics import period
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_native_direct_time_trial import matching_target, snapshot
from verify_web_source_progress import WebSourceProbe


def zero_normalized_match(before,after,seconds,start):
    """For diagnostics only: distinguish harmless zero keys from data changes."""
    return matching_target(before,after,seconds,start,allow_added_zero=True)


def native_accounting_check(metadata,counts,months):
    code="""require('setupkoenv');package.path='/source/?.lua;'..package.path
local json=require('json');local value=json.decode(io.read('*a'))
local result=require('weread.lib.readtime_accounting').check(value.metadata,value.counts,value.months)
io.write(json.encode({target=result and result.kind=='target' or false,
    added=result and result.added_zero_buckets or 0}))"""
    payload=dict(metadata=metadata,counts=counts,months=months)
    child=subprocess.run(['docker','exec','-i','-w','/validation/runtime/lib/koreader',
        '-e','LD_LIBRARY_PATH=/validation/runtime/lib/koreader/libs','weread-validation','./luajit','-e',code],
        input=json.dumps(payload).encode(),stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=15,check=True)
    if len(child.stdout)>65536:raise ValueError('native_accounting_output')
    result=json.loads(child.stdout.splitlines()[-1])
    if set(result)!={'target','added'} or type(result['target']) is not bool or type(result['added']) is not int:
        raise ValueError('native_accounting_result')
    return result


def main():
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    report=dict(result='UNVERIFIED',account_data_posts=0,authentication_posts=0,private_data_in_report=False,
        plugin_settlement_verified=False,one_shot_record_retained=True)
    web=None
    try:
        value,_=Intent().read()
        if not value or value['phase'] not in ('acknowledged','verified'):raise ValueError('no_acknowledged_trial')
        plan=value['plan'];selection=plan['selection'];baseline=plan['baseline']
        saved=SessionStore().load();grant=NativeSessionStore().load(saved['vid'])
        if saved['vid']!=grant['vid'] or plan['record']['account']!=account_key(saved['vid']):raise ValueError('account_mismatch')
        web=WebSourceProbe();web.vid=saved['vid']
        for key,item in saved['cookies'].items():web.set_cookie(key,item)
        web.verify_account()
        after=snapshot(grant,selection['book_id'],web);time.sleep(2)
        second=snapshot(grant,selection['book_id'],web)
        seconds=selection['seconds'];start=selection['protocol_rows'][0]['start_time']
        month=str(period('monthly',start)[0]);before_month=baseline['months'][month];after_month=second['months'][month]
        day_key=str(day(start))
        native=native_accounting_check(plan['record']['metadata'],second['counts'],second['months'])
        report.update(independent_readbacks=2,stable=after==second,
            position_unchanged=all(baseline[k]==second[k] for k in ('native_point','web_point')),
            shelf_unchanged=baseline['shelf_hash']==second['shelf_hash'],
            requested_seconds=seconds,
            book_seconds_delta=second['counts']['readingTime']-baseline['counts']['readingTime'],
            month_seconds_delta=after_month['totalReadTime']-before_month['totalReadTime'],
            day_seconds_delta=after_month['readTimes'].get(day_key,0)-before_month['readTimes'].get(day_key,0),
            read_days_delta=after_month['readDays']-before_month['readDays'],
            other_day_changes=sum(1 for k in set(before_month['readTimes'])|set(after_month['readTimes'])
                if k!=day_key and before_month['readTimes'].get(k,0)!=after_month['readTimes'].get(k,0)),
            other_days_added=sum(1 for k in after_month['readTimes'] if k!=day_key and k not in before_month['readTimes']),
            other_days_removed_nonzero=sum(1 for k,v in before_month['readTimes'].items()
                if k!=day_key and k not in after_month['readTimes'] and v!=0),
            other_book_counters_unchanged=all(baseline['counts'][k]==second['counts'][k] for k in ('recordReadingTime','ttsTime')),
            exact_time_and_statistics=matching_target(baseline,second,seconds,start),
            zero_normalized_time_and_statistics=zero_normalized_match(baseline,second,seconds,start),
            native_accounting_target=native['target'],native_added_zero_buckets=native['added'])
        if report['stable'] and report['position_unchanged'] and report['shelf_unchanged'] and report['exact_time_and_statistics']:
            report.update(result='DIRECT_NATIVE_TIME_ACCOUNTING_VERIFIED',seconds=seconds)
        elif (report['stable'] and report['position_unchanged'] and report['shelf_unchanged']
                and report['zero_normalized_time_and_statistics'] and native['target']):
            report.update(result='DIRECT_NATIVE_TIME_CLOUD_DELTA_VERIFIED',seconds=seconds)
    except Exception:
        report['reason']='readback_unavailable'
    finally:
        if web:web.close()
    print(json.dumps(report));return int(report['result'] not in
        ('DIRECT_NATIVE_TIME_ACCOUNTING_VERIFIED','DIRECT_NATIVE_TIME_CLOUD_DELTA_VERIFIED'))


if __name__=='__main__':raise SystemExit(main())
