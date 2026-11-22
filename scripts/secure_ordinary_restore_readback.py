"""Immutable proof binding for resolving a sent restore by readback only."""
from contextlib import nullcontext
import json
from pathlib import Path
import re
import secrets
import tempfile

from secure_native_session import project_lock
from secure_shelf_experiment import Receipt,canonical
from secure_weread_session import ACCOUNT,MacKeychain,StoreError

SERVICE='org.codex.weread.goal-ordinary-restore-readback-v2'
FIELDS={'original_intent_sha256','owner_sha256','native_grant_sha256','renewal_bridge_sha256',
        'source_sha256','catalog_sha256','web_shelf_core_sha256','native_shelf_core_sha256'}


def validate_binding(value):
    if (not isinstance(value,dict) or set(value)!=FIELDS or any(not isinstance(value[key],str)
            or not re.fullmatch(r'[a-f0-9]{64}',value[key]) for key in FIELDS)):
        raise StoreError('ordinary_restore_readback/binding')
    return value


class RestoreReadbackStore:
    service=SERVICE
    lock_name='codex-ordinary-restore-readback-v2-'
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
            if (not isinstance(value,dict) or set(value)!={'schema','scope','attempt','phase','binding'}
                    or type(value['schema']) is not int or value['schema']!=1 or value['scope']!=ACCOUNT
                    or value['phase']!='verified' or not isinstance(value['attempt'],str)
                    or not re.fullmatch(r'[a-f0-9]{32}',value['attempt'])):raise ValueError()
            validate_binding(value['binding']);return value,raw
        except Exception:raise StoreError('ordinary_restore_readback/invalid') from None
    def read(self):
        with self.lock():
            value,raw=self._load();return value,Receipt(raw) if raw else None
    def record(self,binding):
        validate_binding(binding)
        with self.lock():
            if self._load()[0] is not None:raise StoreError('ordinary_restore_readback/consumed')
            value=dict(schema=1,scope=ACCOUNT,attempt=secrets.token_hex(16),phase='verified',binding=binding)
            raw=canonical(value);self.backend.save(raw)
            if self.backend.load()!=raw:raise StoreError('ordinary_restore_readback/readback')
            self._load();return Receipt(raw)


class ThirdRestoreReadbackStore(RestoreReadbackStore):
    service='org.codex.weread.goal-ordinary-restore-readback-v3'
    lock_name='codex-ordinary-restore-readback-v3-'
