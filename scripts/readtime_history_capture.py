"""Bounded provenance for one real two-second window, not a dispatch grant."""
from contextlib import nullcontext
import json,re,tempfile
from pathlib import Path
from annotation_experiment_model import canonical
from readtime_upload_model import integer,zone
from selection_trial_model import validate_plan as validate_source
from secure_highlight_trial import Receipt
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,MacKeychain,StoreError

SERVICE='org.codex.weread.goal-cross-day-time-capture-v1'
FIELDS={'protocol','source','device_sha256','counters_sha256','start_time','duration','time_zone','book_version',
    'captured_at','not_before','monotonic_elapsed_ms','clock_elapsed_ms'}


def next_cst_day(stamp):return (stamp+28800)//86400*86400-28800+86400


def validate(value):
    if not isinstance(value,dict) or set(value)!=FIELDS or value['protocol']!='cross-day-real-window-two-second-v1':raise ValueError('history_capture/plan')
    validate_source(value['source']);zone(value['time_zone'])
    if (any(not isinstance(value[k],str) or not re.fullmatch('[a-f0-9]{64}',value[k]) for k in ('device_sha256','counters_sha256'))
            or not integer(value['start_time'],1,4102358398) or type(value['duration']) is not int or value['duration']!=2
            or not integer(value['captured_at'],value['start_time']+2,value['start_time']+3)
            or not integer(value['book_version'],1,2147483647)
            or not integer(value['not_before'],1,4102444800) or value['not_before']!=next_cst_day(value['start_time'])+1
            or not integer(value['monotonic_elapsed_ms'],2000,4000) or not integer(value['clock_elapsed_ms'],2000,4000)
            or abs(value['monotonic_elapsed_ms']-value['clock_elapsed_ms'])>250
            or next_cst_day(value['start_time'])!=next_cst_day(value['start_time']+1)):
        raise ValueError('history_capture/plan')
    return value


class CaptureStore:
    """One immutable captured window. This class deliberately has no send/claim."""
    def __init__(self,backend=None,lock=None):
        self.backend=backend if backend is not None else MacKeychain(service=SERVICE,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/('codex-cross-day-time-capture-'+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)

    def _load(self):
        raw=self.backend.load()
        if raw is None:return None,None
        try:
            if not isinstance(raw,bytes) or not 0<len(raw)<=8192:raise ValueError()
            value=json.loads(raw)
            if (not isinstance(value,dict) or set(value)!={'schema','scope','phase','plan'} or type(value['schema']) is not int
                    or value['schema']!=1 or value['scope']!=ACCOUNT or value['phase']!='captured'):raise ValueError()
            validate(value['plan']);return value,raw
        except (TypeError,ValueError,KeyError):raise StoreError('history_capture/invalid') from None

    def read(self):
        with self.lock():
            value,raw=self._load();return value,Receipt(raw) if raw else None

    def capture(self,plan):
        validate(plan)
        with self.lock():
            if self._load()[0] is not None:raise StoreError('history_capture/already_captured')
            value=dict(schema=1,scope=ACCOUNT,phase='captured',plan=plan);raw=canonical(value)
            if len(raw)>8192:raise StoreError('history_capture/invalid')
            self.backend.save(raw)
            if self.backend.load()!=raw:raise StoreError('history_capture/readback')
            self._load();return Receipt(raw)
