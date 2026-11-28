"""Separate two-second current-source experiment, not a historical ledger grant."""
import re
from annotation_experiment_model import digest
from readtime_upload_model import integer
from selection_trial_model import validate_plan as source_plan

LEGACY_PROTOCOL='current-source-time-only-two-second-once-v1'
PROTOCOL='current-source-time-only-two-second-once-v2'
FIELDS={'protocol','source','request_sha256','grant_sha256','counters_sha256','start_time','duration','book_version'}


def validate_plan(value,*,version=2):
    fields=FIELDS if version==1 else FIELDS|{'statistics_sha256','time_zone'}
    if type(version) is not int or version not in (1,2) or not isinstance(value,dict) or set(value)!=fields or value['protocol']!=(LEGACY_PROTOCOL if version==1 else PROTOCOL):raise ValueError('readtime/plan')
    source_plan(value['source'])
    if version==2:
        from readtime_upload_model import zone
        zone(value['time_zone'])
        if not isinstance(value['statistics_sha256'],str) or not re.fullmatch('[a-f0-9]{64}',value['statistics_sha256']):raise ValueError('readtime/plan')
    if (any(not isinstance(value[k],str) or not re.fullmatch('[a-f0-9]{64}',value[k]) for k in ('request_sha256','grant_sha256','counters_sha256'))
            or not integer(value['start_time'],1,4102444800) or type(value['duration']) is not int or value['duration']!=2
            or not integer(value['book_version'],1,2147483647)):raise ValueError('readtime/plan')
    return value


def bind(source,body,credentials,counters,rows,statistics):
    if len(rows)!=1 or rows[0]['duration']!=2:raise ValueError('readtime/scope')
    return validate_plan(dict(protocol=PROTOCOL,source=source,request_sha256=digest(body),grant_sha256=digest(credentials),counters_sha256=digest(counters),
        start_time=rows[0]['start_time'],duration=2,book_version=rows[0]['book_version'],statistics_sha256=digest(statistics),time_zone=rows[0]['time_zone']))
