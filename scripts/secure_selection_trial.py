"""Separate one-shot four-slot reservation; never contains login or book text."""
from contextlib import nullcontext
from dataclasses import dataclass
from datetime import datetime,timezone
import json
from pathlib import Path
import re
import secrets
import tempfile
from annotation_experiment_model import canonical,valid_key
from selection_trial_model import validate_plan
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,MacKeychain,StoreError

SERVICE='org.codex.weread.goal-native-selection-trial'
FIELDS={'schema','scope','attempt','created_at','phase','reserved_posts','native_steps','plan','created_id','mark','cleanup_pending','cleanup_verified'}


@dataclass(frozen=True,repr=False)
class Receipt:
    raw:bytes


class SelectionTrialStore:
    def __init__(self,backend=None,lock=None):
        self.backend=backend if backend is not None else MacKeychain(service=SERVICE,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/('codex-selection-trial-'+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)

    def _load(self):
        raw=self.backend.load()
        if raw is None:return None,None
        try:
            if not isinstance(raw,bytes) or not 0<len(raw)<=8192:raise ValueError()
            v=json.loads(raw)
            if (not isinstance(raw,bytes) or not 0<len(raw)<=8192 or not isinstance(v,dict) or set(v)!=FIELDS
                    or type(v['schema']) is not int or v['schema']!=1 or v['scope']!=ACCOUNT or v['phase'] not in ('prepared','pending','verified')
                    or not isinstance(v['attempt'],str) or not re.fullmatch('[a-f0-9]{32}',v['attempt'])
                    or not isinstance(v['created_at'],str) or not 1<=len(v['created_at'])<=64
                    or type(v['reserved_posts']) is not int or type(v['native_steps']) is not int or not 0<=v['native_steps']<=3
                    or type(v['cleanup_pending']) is not bool or type(v['cleanup_verified']) is not bool):raise ValueError()
            validate_plan(v['plan'])
            if v['phase']=='prepared':
                if v['reserved_posts'] or v['native_steps'] or v['created_id'] is not None or v['mark'] is not None or v['cleanup_pending'] or v['cleanup_verified']:raise ValueError()
            elif v['reserved_posts']!=4:raise ValueError()
            if v['native_steps']==0:
                if v['created_id'] is not None or v['mark'] is not None:raise ValueError()
            elif not valid_key(v['created_id']):raise ValueError()
            mark=v['mark']
            if mark is not None and (not isinstance(mark,dict) or set(mark)!={'id','sha256'} or not valid_key(mark['id'])
                    or not isinstance(mark['sha256'],str) or not re.fullmatch('[a-f0-9]{64}',mark['sha256'])):raise ValueError()
            if (v['cleanup_pending'] and (v['native_steps']!=3 or mark is None or v['cleanup_verified'])
                    or v['cleanup_verified'] and v['native_steps']!=3 or v['phase']=='verified' and not v['cleanup_verified']):raise ValueError()
            return v,raw
        except (ValueError,TypeError,KeyError,UnicodeError):raise StoreError('selection_trial/intent_invalid') from None

    def read(self):
        with self.lock():
            value,raw=self._load();return value,Receipt(raw) if raw else None

    def pending(self):return self.read()[0] is not None

    def _write(self,v):
        raw=canonical(v)
        if len(raw)>8192:raise StoreError('selection_trial/intent_invalid')
        self.backend.save(raw)
        if self.backend.load()!=raw:raise StoreError('selection_trial/intent_readback')
        self._load();return Receipt(raw)

    def prepare(self,plan):
        validate_plan(plan)
        with self.lock():
            if self._load()[0] is not None:raise StoreError('selection_trial/intent_exists')
            return self._write(dict(schema=1,scope=ACCOUNT,attempt=secrets.token_hex(16),created_at=datetime.now(timezone.utc).isoformat(),
                phase='prepared',reserved_posts=0,native_steps=0,plan=plan,created_id=None,mark=None,cleanup_pending=False,cleanup_verified=False))

    def _owned(self,receipt,phase):
        value,raw=self._load()
        if not isinstance(receipt,Receipt) or raw!=receipt.raw or value is None or value['phase']!=phase:raise StoreError('selection_trial/intent_replaced')
        return value

    def claim(self,receipt):
        with self.lock():
            v=self._owned(receipt,'prepared');v.update(phase='pending',reserved_posts=4);return self._write(v)

    def native_step(self,receipt,step,created_id,mark):
        if mark is not None and (not isinstance(mark,dict) or set(mark)!={'id','sha256'} or not valid_key(mark['id'])
                or not isinstance(mark['sha256'],str) or not re.fullmatch('[a-f0-9]{64}',mark['sha256'])):raise StoreError('selection_trial/step')
        with self.lock():
            v=self._owned(receipt,'pending')
            if (type(step) is not int or step!=v['native_steps']+1 or not 1<=step<=3 or not valid_key(created_id)
                    or v['created_id'] is not None and v['created_id']!=created_id
                    or v['mark'] is not None and mark is not None and v['mark']!=mark):raise StoreError('selection_trial/step')
            v.update(native_steps=step,created_id=created_id,mark=mark or v['mark']);return self._write(v)

    def claim_cleanup(self,receipt):
        with self.lock():
            v=self._owned(receipt,'pending')
            if v['native_steps']!=3 or v['mark'] is None or v['cleanup_pending'] or v['cleanup_verified']:raise StoreError('selection_trial/cleanup')
            v['cleanup_pending']=True;return self._write(v)

    def verified_cleanup(self,receipt):
        with self.lock():
            v=self._owned(receipt,'pending')
            if v['native_steps']!=3 or v['cleanup_verified']:raise StoreError('selection_trial/cleanup')
            v.update(cleanup_pending=False,cleanup_verified=True);return self._write(v)

    def complete(self,receipt):
        with self.lock():
            v=self._owned(receipt,'pending')
            if v['native_steps']!=3 or not v['cleanup_verified'] or v['cleanup_pending']:raise StoreError('selection_trial/unverified')
            v['phase']='verified';return self._write(v)

    def finish(self,receipt,*,discard_prepared=False):
        with self.lock():
            self._owned(receipt,'prepared' if discard_prepared else 'verified');self.backend.delete()
            if self.backend.load() is not None:raise StoreError('selection_trial/cleanup_failed')
