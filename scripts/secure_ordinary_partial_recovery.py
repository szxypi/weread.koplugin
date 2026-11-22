"""One non-replayable recovery of an acknowledged, partially verified enter.

The separate Keychain record binds the original intent and current shelf hashes.
No credentials, book contents, network operations or implicit retries occur here.
"""
from contextlib import nullcontext
import json
from pathlib import Path
import re
import secrets
import tempfile

from secure_native_session import project_lock
from secure_shelf_experiment import Receipt, canonical
from secure_weread_session import ACCOUNT, MacKeychain, StoreError

SERVICE='org.codex.weread.goal-ordinary-partial-recovery-v1'
PHASES={'prepared':0,'pending':1,'acknowledged':1,'retired':1}
TRANSITIONS={('prepared','pending'),('pending','acknowledged'),('acknowledged','retired')}
FIELDS={'original_intent_sha256','web_shelf_sha256','native_shelf_sha256','web_shelf_core_sha256','native_shelf_core_sha256',
        'native_grant_sha256','renewal_bridge_sha256'}


def validate_binding(value):
    if (not isinstance(value,dict) or set(value)!=FIELDS or any(not isinstance(value[k],str)
            or not re.fullmatch(r'[a-f0-9]{64}',value[k]) for k in FIELDS)):
        raise StoreError('ordinary_recovery/binding')
    return value


class PartialRecoveryStore:
    def __init__(self,backend=None,lock=None):
        self.backend=backend if backend is not None else MacKeychain(service=SERVICE,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/('codex-ordinary-partial-recovery-'+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)
    def _load(self):
        raw=self.backend.load()
        if raw is None:return None,None
        try:
            if not isinstance(raw,bytes) or not 0<len(raw)<=4096:raise ValueError()
            value=json.loads(raw)
            if (not isinstance(value,dict) or set(value)!={'schema','scope','attempt','phase','posts','binding'}
                    or type(value['schema']) is not int or value['schema']!=1 or value['scope']!=ACCOUNT
                    or not isinstance(value['attempt'],str) or not re.fullmatch(r'[a-f0-9]{32}',value['attempt'])
                    or value['phase'] not in PHASES or type(value['posts']) is not int or value['posts']!=PHASES[value['phase']]):raise ValueError()
            validate_binding(value['binding']);return value,raw
        except Exception:raise StoreError('ordinary_recovery/intent_invalid') from None
    def read(self):
        with self.lock():
            value,raw=self._load();return value,Receipt(raw) if raw else None
    def pending(self):
        value,_=self.read();return value is not None and value['phase']!='retired'
    def _write(self,value):
        raw=canonical(value);self.backend.save(raw)
        if self.backend.load()!=raw:raise StoreError('ordinary_recovery/readback')
        self._load();return Receipt(raw)
    def reserve(self,binding):
        validate_binding(binding)
        with self.lock():
            if self._load()[0] is not None:raise StoreError('ordinary_recovery/consumed')
            return self._write(dict(schema=1,scope=ACCOUNT,attempt=secrets.token_hex(16),phase='prepared',posts=0,binding=binding))
    def advance(self,receipt,before,after):
        if (before,after) not in TRANSITIONS:raise StoreError('ordinary_recovery/phase')
        with self.lock():
            value,raw=self._load()
            if not isinstance(receipt,Receipt) or raw!=receipt.pending or not value or value['phase']!=before:
                raise StoreError('ordinary_recovery/replaced')
            value['phase'],value['posts']=after,PHASES[after];return self._write(value)
