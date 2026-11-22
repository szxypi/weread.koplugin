"""Single-use binding between an expired native grant and verified replacement."""
from contextlib import nullcontext
import json
from pathlib import Path
import re
import secrets
import tempfile

from secure_native_session import project_lock
from secure_shelf_experiment import Receipt,canonical
from secure_weread_session import ACCOUNT,MacKeychain,StoreError

SERVICE='org.codex.weread.goal-ordinary-recovery-renewal-v1'
FIELDS={'original_intent_sha256','owner_sha256','device_sha256','old_grant_sha256'}


def validate_binding(value):
    if (not isinstance(value,dict) or set(value)!=FIELDS or any(not isinstance(value[k],str)
            or not re.fullmatch(r'[a-f0-9]{64}',value[k]) for k in FIELDS)):
        raise StoreError('ordinary_renewal/binding')
    return value


class RecoveryRenewalStore:
    service=SERVICE
    lock_name='codex-ordinary-recovery-renewal-'
    def __init__(self,backend=None,lock=None):
        self.backend=backend if backend is not None else MacKeychain(service=self.service,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/(self.lock_name+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)
    def _load(self):
        raw=self.backend.load()
        if raw is None:return None,None
        try:
            if not isinstance(raw,bytes) or not 0<len(raw)<=4096:raise ValueError()
            value=json.loads(raw)
            if (not isinstance(value,dict) or set(value)!={'schema','scope','attempt','phase','binding','new_grant_sha256'}
                    or type(value['schema']) is not int or value['schema']!=1 or value['scope']!=ACCOUNT
                    or not isinstance(value['attempt'],str) or not re.fullmatch(r'[a-f0-9]{32}',value['attempt'])
                    or value['phase'] not in ('prepared','pending','verified')):raise ValueError()
            validate_binding(value['binding']);new=value['new_grant_sha256']
            if (value['phase']=='verified' and (not isinstance(new,str) or not re.fullmatch(r'[a-f0-9]{64}',new))
                    or value['phase']!='verified' and new is not None):raise ValueError()
            return value,raw
        except Exception:raise StoreError('ordinary_renewal/intent_invalid') from None
    def read(self):
        with self.lock():
            value,raw=self._load();return value,Receipt(raw) if raw else None
    def _write(self,value):
        raw=canonical(value);self.backend.save(raw)
        if self.backend.load()!=raw:raise StoreError('ordinary_renewal/readback')
        self._load();return Receipt(raw)
    def reserve(self,binding):
        validate_binding(binding)
        with self.lock():
            if self._load()[0] is not None:raise StoreError('ordinary_renewal/consumed')
            return self._write(dict(schema=1,scope=ACCOUNT,attempt=secrets.token_hex(16),phase='prepared',binding=binding,new_grant_sha256=None))
    def claim(self,receipt):
        with self.lock():
            value,raw=self._load()
            if not isinstance(receipt,Receipt) or not value or raw!=receipt.pending or value['phase']!='prepared':raise StoreError('ordinary_renewal/replaced')
            value['phase']='pending';return self._write(value)
    def finish(self,receipt,new_grant_sha256):
        if not isinstance(new_grant_sha256,str) or not re.fullmatch(r'[a-f0-9]{64}',new_grant_sha256):raise StoreError('ordinary_renewal/binding')
        with self.lock():
            value,raw=self._load()
            if not isinstance(receipt,Receipt) or not value or raw!=receipt.pending or value['phase']!='pending':raise StoreError('ordinary_renewal/replaced')
            value['phase']='verified';value['new_grant_sha256']=new_grant_sha256;return self._write(value)


class RetryRecoveryRenewalStore(RecoveryRenewalStore):
    service='org.codex.weread.goal-ordinary-recovery-renewal-v2'
    lock_name='codex-ordinary-recovery-renewal-v2-'


class ThirdRecoveryRenewalStore(RetryRecoveryRenewalStore):
    service='org.codex.weread.goal-ordinary-recovery-renewal-v3'
    lock_name='codex-ordinary-recovery-renewal-v3-'
