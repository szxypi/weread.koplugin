"""One-shot native UI trial reservation, distinct from the prior Python trial.

All three possible writes are reserved durably before starting an armed
process. A crash never makes a remaining slot reusable. Independent readback
records progress, but pending trials can only be inspected, not relaunched.
"""
from contextlib import nullcontext
from dataclasses import dataclass
from datetime import datetime,timezone
import json
from pathlib import Path
import re
import secrets
import tempfile
from annotation_experiment_model import canonical,validate_plan,valid_key
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,MacKeychain,StoreError

SERVICE='org.codex.weread.goal-native-thought-trial'
FIELDS={'schema','scope','attempt','created_at','phase','reserved_posts','verified_steps','plan','created_id'}


@dataclass(frozen=True,repr=False)
class Receipt:
    raw:bytes


class NativeThoughtTrialStore:
    def __init__(self,backend=None,lock=None):
        self.backend=backend if backend is not None else MacKeychain(service=SERVICE,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/('codex-native-thought-'+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)

    def _load(self):
        raw=self.backend.load()
        if raw is None:return None,None
        try:
            if not isinstance(raw,bytes) or not 0<len(raw)<=8192:raise ValueError()
            value=json.loads(raw)
            if (not isinstance(value,dict) or set(value)!=FIELDS or type(value['schema']) is not int or value['schema']!=1
                    or value['scope']!=ACCOUNT or not isinstance(value['phase'],str) or value['phase'] not in ('prepared','pending','verified')
                    or not isinstance(value['attempt'],str) or not re.fullmatch('[a-f0-9]{32}',value['attempt'])
                    or not isinstance(value['created_at'],str) or not 1<=len(value['created_at'])<=64
                    or type(value['reserved_posts']) is not int or type(value['verified_steps']) is not int):raise ValueError()
            validate_plan(value['plan'])
            if value['phase']=='prepared':
                if value['reserved_posts']!=0 or value['verified_steps']!=0 or value['created_id'] is not None:raise ValueError()
            elif value['reserved_posts']!=3 or not 0<=value['verified_steps']<=3:raise ValueError()
            if value['phase']=='verified' and value['verified_steps']!=3:raise ValueError()
            if value['verified_steps']==0:
                if value['created_id'] is not None:raise ValueError()
            elif not valid_key(value['created_id']):raise ValueError()
            return value,raw
        except (ValueError,TypeError,UnicodeError,KeyError):raise StoreError('native_thought_intent_invalid') from None

    def _write(self,value):
        raw=canonical(value)
        if len(raw)>8192:raise StoreError('native_thought_intent_invalid')
        self.backend.save(raw)
        if self.backend.load()!=raw:raise StoreError('native_thought_intent_readback_failed')
        self._load();return Receipt(raw)

    def read(self):
        with self.lock():
            value,raw=self._load();return value,Receipt(raw) if raw else None

    def pending(self):
        with self.lock():return self._load()[0] is not None

    def prepare(self,plan):
        validate_plan(plan)
        with self.lock():
            if self._load()[0] is not None:raise StoreError('native_thought_intent_exists')
            return self._write(dict(schema=1,scope=ACCOUNT,attempt=secrets.token_hex(16),created_at=datetime.now(timezone.utc).isoformat(),
                phase='prepared',reserved_posts=0,verified_steps=0,plan=plan,created_id=None))

    def _owned(self,receipt,phase):
        value,raw=self._load()
        if not isinstance(receipt,Receipt) or raw!=receipt.raw or value is None or value['phase']!=phase:raise StoreError('native_thought_intent_replaced')
        return value

    def claim(self,receipt):
        with self.lock():
            value=self._owned(receipt,'prepared');value.update(phase='pending',reserved_posts=3)
            return self._write(value)

    def verified_step(self,receipt,step,created_id):
        with self.lock():
            value=self._owned(receipt,'pending')
            if (type(step) is not int or step!=value['verified_steps']+1 or not 1<=step<=3 or not valid_key(created_id)
                    or value['created_id'] is not None and created_id!=value['created_id']):raise StoreError('native_thought_step_invalid')
            value.update(verified_steps=step,created_id=created_id)
            return self._write(value)

    def complete(self,receipt):
        with self.lock():
            value=self._owned(receipt,'pending')
            if value['verified_steps']!=3:raise StoreError('native_thought_unverified')
            value['phase']='verified';return self._write(value)

    def finish(self,receipt,*,discard_prepared=False):
        with self.lock():
            self._owned(receipt,'prepared' if discard_prepared else 'verified')
            self.backend.delete()
            if self.backend.load() is not None:raise StoreError('native_thought_cleanup_failed')
