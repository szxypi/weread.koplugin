"""Independent, read-only accounting comparison for a native time bundle.

This pure model cannot perform transport, certify the provenance of observations,
advance a receipt, or itself prove that any account write took place.
"""
from copy import deepcopy

from annotation_experiment_model import digest
from native_time_bundle_gate import binding,day
from readtime_statistics import compare,validate as validate_months
from readtime_upload_model import integer
from txt_full_summary import digest as captured_digest
from verify_native_position_lua import equivalent
from verify_native_statistics import period
from web_shelf_contract import identity

SNAPSHOT_FIELDS={'point','web_point','counts','version','shelf','source','catalog'}
COUNT_FIELDS={'readingTime','recordReadingTime','ttsTime'}
BASELINE_FIELDS={'bundle_sha256','owner_sha256','device_sha256','prepared_at','snapshot','months'}


def baseline(bundle,grant,snapshot,months,prepared_at):
    scope=binding(bundle,grant,prepared_at)
    p=bundle['plan']
    if (not isinstance(snapshot,dict) or set(snapshot)!=SNAPSHOT_FIELDS
            or captured_digest(snapshot)!=p['baseline_sha256'] or snapshot['version']!=p['book_version']
            or snapshot['source']!=p['raw_sha256'] or not isinstance(snapshot['point'],dict)
            or identity(snapshot['point'].get('chapter_uid'))!=p['chapter_uid']
            or snapshot['point'].get('chapter_idx')!=p['chapter_idx']):
        raise ValueError('bundle_accounting/baseline')
    counts=snapshot.get('counts')
    if (not isinstance(counts,dict) or set(counts)!=COUNT_FIELDS
            or any(not integer(counts[k],0,2**53-1) for k in COUNT_FIELDS)
            or counts['readingTime']>2**53-1-p['seconds']):
        raise ValueError('bundle_accounting/counters')
    validate_months(months)
    wanted={str(period('monthly',p['start_time'])[0]),str(period('monthly',prepared_at)[0])}
    if set(months)!=wanted:raise ValueError('bundle_accounting/months')
    return dict(bundle_sha256=digest(bundle),owner_sha256=scope['owner_sha256'],device_sha256=scope['device_sha256'],prepared_at=prepared_at,
                snapshot=deepcopy(snapshot),months=deepcopy(months))


def audit(bundle,grant,before,samples,dispatch_at):
    if not isinstance(before,dict) or set(before)!=BASELINE_FIELDS:raise ValueError('bundle_accounting/baseline')
    original=baseline(bundle,grant,before['snapshot'],before['months'],before['prepared_at'])
    if not equivalent(before,original):raise ValueError('bundle_accounting/baseline')
    p=bundle['plan']
    if (not integer(dispatch_at,p['not_before'],4102444800)
            or not 0<=dispatch_at-before['prepared_at']<30 or day(dispatch_at)!=day(before['prepared_at'])):
        raise ValueError('bundle_accounting/dispatch_time')
    if not isinstance(samples,list) or len(samples)!=3:raise ValueError('bundle_accounting/samples')
    last_time=0
    for item in samples:
        if (not isinstance(item,dict) or set(item)!={'snapshot','months','server_at'}
                or not integer(item['server_at'],p['not_before'],4102444800)
                or not dispatch_at-60<=item['server_at']<=dispatch_at+180 or item['server_at']<last_time):
            raise ValueError('bundle_accounting/server_clock')
        last_time=item['server_at'];validate_months(item['months'])
    first=samples[0]
    if any(not equivalent({'snapshot':first['snapshot'],'months':first['months']},
                          {'snapshot':s['snapshot'],'months':s['months']}) for s in samples[1:]):
        raise ValueError('bundle_accounting/unstable')
    target=deepcopy(before['snapshot']);target['counts']['readingTime']+=p['seconds']
    after_counts=first['snapshot'].get('counts') if isinstance(first['snapshot'],dict) else None
    if not isinstance(after_counts,dict) or set(after_counts)!=COUNT_FIELDS or any(not integer(after_counts[k],0,2**53-1) for k in COUNT_FIELDS):
        raise ValueError('bundle_accounting/counters')
    if not equivalent(target,first['snapshot']):raise ValueError('bundle_accounting/changed')
    month=str(period('monthly',p['start_time'])[0]);key=str(day(p['start_time']))
    target_months=deepcopy(before['months']);historical=target_months[month]
    historical['readTimes'][key]=historical['readTimes'].get(key,0)+p['seconds']
    historical['totalReadTime']+=p['seconds']
    matches=[]
    for delta in (0,1):
        expected=deepcopy(target_months);expected[month]['readDays']+=delta
        try:result=compare(expected,first['months'])
        except ValueError:continue
        if result is not None:matches.append((delta,result['removed_zero_buckets']))
    if len(matches)!=1:raise ValueError('bundle_accounting/changed')
    return {'result':'ACCOUNTING_MATCH','seconds':p['seconds'],'independent_samples':3,
            'read_days_delta':matches[0][0],'removed_zero_buckets':matches[0][1],
            'other_counters_positions_source_shelf_exact':True,'real_accounting_verified':False}
