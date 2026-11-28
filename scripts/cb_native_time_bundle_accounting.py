"""Independent CB historical-time baseline and three-read accounting audit.

Pure model only: it cannot fetch, transmit, authorize or assert a real write.
The caller must independently establish the provenance of each observation.
"""
from copy import deepcopy

from annotation_experiment_model import digest
from cb_native_time_bundle_gate import binding,day
from readtime_statistics import compare,validate as validate_months
from readtime_upload_model import integer
from verify_native_position_lua import equivalent
from verify_native_statistics import period

FIELDS={'bundle_sha256','owner_sha256','device_sha256','prepared_at','snapshot','months'}


def baseline(bundle,grant,snapshot,months,prepared_at):
    scope=binding(bundle,grant,snapshot,prepared_at);plan=bundle['plan'];counts=snapshot['counts']
    if counts['readingTime']>2**53-1-plan['seconds']:raise ValueError('cb_accounting/counters')
    validate_months(months)
    wanted={str(period('monthly',plan['start_time'])[0]),str(period('monthly',prepared_at)[0])}
    if set(months)!=wanted:raise ValueError('cb_accounting/months')
    return dict(bundle_sha256=digest(bundle),owner_sha256=scope['owner_sha256'],device_sha256=scope['device_sha256'],
                prepared_at=prepared_at,snapshot=deepcopy(snapshot),months=deepcopy(months))


def audit(bundle,grant,before,samples,dispatch_at):
    if not isinstance(before,dict) or set(before)!=FIELDS:raise ValueError('cb_accounting/baseline')
    original=baseline(bundle,grant,before['snapshot'],before['months'],before['prepared_at'])
    if not equivalent(before,original):raise ValueError('cb_accounting/baseline')
    plan=bundle['plan']
    if (not integer(dispatch_at,plan['not_before'],4102444800) or not 0<=dispatch_at-before['prepared_at']<30
            or day(dispatch_at)!=day(before['prepared_at'])):raise ValueError('cb_accounting/dispatch_time')
    if not isinstance(samples,list) or len(samples)!=3:raise ValueError('cb_accounting/samples')
    previous=0
    for item in samples:
        if (not isinstance(item,dict) or set(item)!={'snapshot','months','server_at'}
                or not integer(item['server_at'],plan['not_before'],4102444800)
                or not dispatch_at-60<=item['server_at']<=dispatch_at+180 or item['server_at']<previous):
            raise ValueError('cb_accounting/server_clock')
        previous=item['server_at'];validate_months(item['months'])
    first=samples[0]
    counts=first['snapshot'].get('counts') if isinstance(first['snapshot'],dict) else None
    if (not isinstance(counts,dict) or set(counts)!={'readingTime','recordReadingTime','ttsTime'}
            or any(not integer(value,0,2**53-1) for value in counts.values())):raise ValueError('cb_accounting/counters')
    if any(not equivalent({'snapshot':first['snapshot'],'months':first['months']},
                          {'snapshot':item['snapshot'],'months':item['months']}) for item in samples[1:]):
        raise ValueError('cb_accounting/unstable')
    target=deepcopy(before['snapshot']);target['counts']['readingTime']+=plan['seconds']
    if not equivalent(target,first['snapshot']):raise ValueError('cb_accounting/changed')
    month=str(period('monthly',plan['start_time'])[0]);key=str(day(plan['start_time']))
    wanted=deepcopy(before['months']);historical=wanted[month]
    historical['readTimes'][key]=historical['readTimes'].get(key,0)+plan['seconds']
    historical['totalReadTime']+=plan['seconds']
    matches=[]
    for delta in (0,1):
        candidate=deepcopy(wanted);candidate[month]['readDays']+=delta
        try:result=compare(candidate,first['months'])
        except ValueError:continue
        if result is not None:matches.append((delta,result['removed_zero_buckets']))
    if len(matches)!=1:raise ValueError('cb_accounting/changed')
    return dict(result='ACCOUNTING_MATCH',seconds=plan['seconds'],independent_samples=3,
                read_days_delta=matches[0][0],removed_zero_buckets=matches[0][1],
                native_and_web_positions_source_shelves_exact=True,real_accounting_verified=False)
