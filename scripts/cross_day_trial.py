"""A distinct one-shot historical protocol scope; never reuses old trials."""
from contextlib import nullcontext
from copy import deepcopy
import json,re,secrets,tempfile
from pathlib import Path
from annotation_experiment_model import canonical,digest
from readtime_history_capture import validate as capture_plan
from readtime_upload_model import integer
from secure_highlight_trial import Receipt
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,MacKeychain,StoreError
from verify_native_statistics import period

PROTOCOL='cross-day-real-capture-two-second-cst-once-v1'
HASHES={'capture_record_sha256','request_sha256','grant_sha256','statistics_sha256'}
FIELDS={'protocol','capture','created_at'}|HASHES
PHASES={'prepared':0,'claimed':1,'acknowledged':1,'verified':1,'retired':1}
TRANSITIONS={('prepared','claimed'),('claimed','acknowledged'),('acknowledged','verified'),('verified','retired')}


def day(stamp):return (stamp+28800)//86400*86400-28800


def validate(value):
    if not isinstance(value,dict) or set(value)!=FIELDS or value['protocol']!=PROTOCOL:raise ValueError('cross_trial/plan')
    p=capture_plan(value['capture'])
    if (p['time_zone']!='+08:00' or not integer(value['created_at'],p['not_before'],4102444800)
            or day(value['created_at'])<=day(p['start_time'])
            or any(not isinstance(value[k],str) or not re.fullmatch('[a-f0-9]{64}',value[k]) for k in HASHES)):
        raise ValueError('cross_trial/plan')
    return value


def bind(capture,record,body,credentials,counts,statistics):
    p=capture_plan(capture)
    if (digest(counts)!=p['counters_sha256'] or digest(credentials['deviceId'])!=p['device_sha256']
            or credentials['vid']!=p['source']['owner'] or record.get('phase')!='captured' or record.get('plan')!=p):
        raise ValueError('cross_trial/baseline')
    return validate(dict(protocol=PROTOCOL,capture=deepcopy(p),capture_record_sha256=digest(record),request_sha256=digest(body),
        grant_sha256=digest(credentials),statistics_sha256=digest(statistics),created_at=body['books'][0]['timestamp']))


def expected_months(before,capture,created_at):
    """Only the historical day may gain two seconds. Current day is fixed."""
    p=capture_plan(capture);month=str(period('monthly',p['start_time'])[0]);current=str(period('monthly',created_at)[0])
    if set(before)!={month,current} or day(created_at)<=day(p['start_time']):raise ValueError('cross_trial/months')
    target=deepcopy(before);stat=target[month];key=str(day(p['start_time']))
    stat['readTimes'][key]=stat['readTimes'].get(key,0)+2;stat['totalReadTime']+=2
    # The qualification threshold for readDays is undocumented. Duration and
    # every daily bucket remain exact; only zero or one qualifying day is allowed.
    return [dict(target,**{month:dict(stat,readDays=stat['readDays']+delta)}) for delta in (0,1)]


class TrialStore:
    service='org.codex.weread.goal-cross-day-time-trial-v1'
    def __init__(self,backend=None,lock=None):
        self.backend=backend if backend is not None else MacKeychain(service=self.service,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/('codex-cross-day-time-trial-'+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)

    def _load(self):
        raw=self.backend.load()
        if raw is None:return None,None
        try:
            if not isinstance(raw,bytes) or not 0<len(raw)<=16384:raise ValueError()
            v=json.loads(raw)
            if (not isinstance(v,dict) or set(v)!={'schema','scope','attempt','phase','posts','plan'} or type(v['schema']) is not int or v['schema']!=1
                    or v['scope']!=ACCOUNT or v['phase'] not in PHASES or type(v['posts']) is not int or v['posts']!=PHASES[v['phase']]
                    or not isinstance(v['attempt'],str) or not re.fullmatch('[a-f0-9]{32}',v['attempt'])):raise ValueError()
            validate(v['plan']);return v,raw
        except (TypeError,ValueError,KeyError):raise StoreError('cross_trial/invalid') from None

    def read(self):
        with self.lock():
            value,raw=self._load();return value,Receipt(raw) if raw else None

    def _write(self,value):
        raw=canonical(value)
        if len(raw)>16384:raise StoreError('cross_trial/invalid')
        self.backend.save(raw)
        if self.backend.load()!=raw:raise StoreError('cross_trial/readback')
        self._load();return Receipt(raw)

    def reserve(self,plan):
        validate(plan)
        with self.lock():
            if self._load()[0] is not None:raise StoreError('cross_trial/consumed')
            return self._write(dict(schema=1,scope=ACCOUNT,attempt=secrets.token_hex(16),phase='prepared',posts=0,plan=plan))

    def advance(self,receipt,before,after):
        if (before,after) not in TRANSITIONS:raise StoreError('cross_trial/phase')
        with self.lock():
            value,raw=self._load()
            if not isinstance(receipt,Receipt) or receipt.raw!=raw or value is None or value['phase']!=before:raise StoreError('cross_trial/replaced')
            value['phase'],value['posts']=after,PHASES[after];return self._write(value)
