"""One durable dispatch claim; interrupted or unknown sends cannot be replayed."""
from contextlib import nullcontext
import json
from pathlib import Path
import secrets,tempfile
from annotation_experiment_model import canonical
from readtime_trial_model import validate_plan
from secure_highlight_trial import Receipt
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,MacKeychain,StoreError

SERVICE='org.codex.weread.goal-current-source-readtime-trial'
SERVICE_V2=SERVICE+'-v2'
PHASES=('prepared','claimed','verified')


def validate_retirement(value):
    fields={'explicit_success_receipt','original_records_exact','web_and_native_positions_exact','independent_counters_stable',
        'book_counter_delta_verified','monthly_baseline_missing','original_trial_unverified','no_replay'}
    if not isinstance(value,dict) or set(value)!=fields or any(value[k] is not True for k in fields):raise StoreError('readtime/retirement_invalid')


class ReadtimeTrialStore:
    def __init__(self,backend=None,lock=None,*,version=2):
        if type(version) is not int or version not in (1,2):raise ValueError('readtime/version')
        self.version=version
        self.backend=backend if backend is not None else MacKeychain(service=SERVICE if version==1 else SERVICE_V2,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/('codex-current-source-readtime-'+str(version)+'-'+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)

    def _load(self):
        raw=self.backend.load()
        if raw is None:return None,None
        try:
            if not isinstance(raw,bytes) or not 0<len(raw)<=8192:raise ValueError()
            value=json.loads(raw)
            if not isinstance(value,dict):raise ValueError()
            if (set(value)!=({'schema','scope','attempt','phase','plan','reserved_posts','retirement'} if self.version==1 and value.get('phase')=='retired' else {'schema','scope','attempt','phase','plan','reserved_posts'}) or type(value['schema']) is not int or value['schema']!=1
                    or value['scope']!=ACCOUNT or value['phase'] not in (PHASES+('retired',) if self.version==1 else PHASES) or type(value['reserved_posts']) is not int or value['reserved_posts']!=1
                    or not isinstance(value['attempt'],str) or len(value['attempt'])!=32 or any(c not in '0123456789abcdef' for c in value['attempt'])):raise ValueError()
            validate_plan(value['plan'],version=self.version)
            if value['phase']=='retired':validate_retirement(value['retirement'])
            return value,raw
        except (TypeError,ValueError,KeyError):raise StoreError('readtime/intent_invalid') from None

    def read(self):
        with self.lock():
            value,raw=self._load();return value,Receipt(raw) if raw else None

    def _write(self,value):
        raw=canonical(value)
        if len(raw)>8192:raise StoreError('readtime/intent_invalid')
        self.backend.save(raw)
        if self.backend.load()!=raw:raise StoreError('readtime/intent_readback')
        self._load();return Receipt(raw)

    def reserve(self,plan):
        if self.version!=2:raise StoreError('readtime/legacy_consumed')
        validate_plan(plan,version=self.version)
        with self.lock():
            if self._load()[0] is not None:raise StoreError('readtime/pending')
            return self._write(dict(schema=1,scope=ACCOUNT,attempt=secrets.token_hex(16),phase='prepared',plan=plan,reserved_posts=1))

    def advance(self,receipt,phase):
        with self.lock():
            value,raw=self._load()
            if (not isinstance(receipt,Receipt) or value is None or receipt.raw!=raw or phase not in PHASES
                    or value['phase'] not in PHASES or PHASES.index(phase)!=PHASES.index(value['phase'])+1):raise StoreError('readtime/replaced')
            value['phase']=phase;return self._write(value)

    def finish(self,receipt):
        with self.lock():
            value,raw=self._load()
            if not isinstance(receipt,Receipt) or value is None or value['phase']!='verified' or receipt.raw!=raw:raise StoreError('readtime/unverified')
            self.backend.delete()
            if self.backend.load() is not None:raise StoreError('readtime/cleanup')


    def retire_legacy(self,receipt,audit):
        """Keep a consumed v1 tombstone; never call the failed trial verified."""
        validate_retirement(audit)
        with self.lock():
            value,raw=self._load()
            if self.version!=1 or not isinstance(receipt,Receipt) or value is None or value['phase']!='claimed' or receipt.raw!=raw:raise StoreError('readtime/retirement_scope')
            value['phase']='retired';value['retirement']=audit;return self._write(value)
