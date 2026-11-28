"""Strict monthly duration comparison with audited zero-bucket removal only.

No network, timestamps edits or receipt advancement. Reconstruction is a bounded
read-only diagnostic: a candidate must match the previously sealed full digest.
It is never a replacement for saving a full private baseline for new uploads.
"""
from copy import deepcopy
from itertools import combinations
import re
from annotation_experiment_model import canonical,digest
from cross_day_trial import day,expected_months,validate as trial_plan
from verify_native_statistics import period,project

FIELDS={'baseTime','readTimes','totalReadTime','readDays'}


def validate(months):
    if not isinstance(months,dict) or not 1<=len(months)<=2:raise ValueError('time_statistics/months')
    for key,row in months.items():
        if (not isinstance(key,str) or not re.fullmatch('[1-9][0-9]{8,9}',key) or not 1<=int(key)<=4102444800
                or not isinstance(row,dict) or set(row)!=FIELDS or period('monthly',int(key))[0]!=int(key)):
            raise ValueError('time_statistics/schema')
        value=project(row,'monthly',int(key))
        if {k:value[k] for k in FIELDS}!=row:raise ValueError('time_statistics/canonical')
    return months


def compare(expected,observed):
    """All values/keys stay exact, except an existing numeric zero may vanish."""
    validate(expected);validate(observed)
    if set(expected)!=set(observed):return None
    removed=0
    for month,left in expected.items():
        right=observed[month]
        if any(left[k]!=right[k] for k in FIELDS-{'readTimes'}):return None
        for key,value in right['readTimes'].items():
            if key not in left['readTimes'] or left['readTimes'][key]!=value:return None
        for key,value in left['readTimes'].items():
            if key not in right['readTimes']:
                if value!=0:return None
                removed+=1
    return dict(removed_zero_buckets=removed)


def match(before,observed,capture,created_at):
    validate(before);validate(observed);matches=[]
    month=str(period('monthly',capture['start_time'])[0])
    for expected in expected_months(before,capture,created_at):
        result=compare(expected,observed)
        if result is not None:matches.append(dict(result,read_days_delta=int(observed[month]['readDays']-before[month]['readDays'])))
    return matches[0] if len(matches)==1 else None


def reconstruct(plan,observed):
    """Return private baseline + fixed audit only for one exact digest match.

    Only the known two-second delta and at most two removed integer-zero day
    buckets are explored. No new zero buckets, other changes or guessed times.
    """
    p=trial_plan(plan);validate(observed);cap=p['capture']
    month=str(period('monthly',cap['start_time'])[0]);current=str(period('monthly',p['created_at'])[0])
    if set(observed)!={month,current}:return None
    key=str(day(cap['start_time']));base=deepcopy(observed)
    if base[month]['readTimes'].get(key,0)<2 or base[month]['totalReadTime']<2:return None
    base[month]['readTimes'][key]-=2;base[month]['totalReadTime']-=2
    options=[base]
    if base[month]['readTimes'][key]==0:
        absent=deepcopy(base);del absent[month]['readTimes'][key];options.append(absent)
    matches={}
    for option in options:
        missing=[(m,str(stamp)) for m,row in option.items()
            for stamp in range(int(m),period('monthly',int(m))[1],86400) if str(stamp) not in row['readTimes']]
        for count in range(3):
            for added in combinations(missing,count):
                candidate=deepcopy(option)
                for m,stamp in added:candidate[m]['readTimes'][stamp]=0
                for delta in (0,1):
                    candidate[month]['readDays']=base[month]['readDays']-delta
                    if digest(candidate)!=p['statistics_sha256']:continue
                    check=match(candidate,observed,cap,p['created_at'])
                    if check is not None and check['removed_zero_buckets']<=2:
                        matches[canonical(candidate)]=(deepcopy(candidate),dict(check,baseline_digest_exact=True))
    return next(iter(matches.values())) if len(matches)==1 else None
