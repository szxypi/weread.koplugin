"""Separate two-slot intent; a stopped native shelf trial cannot be replayed."""
from contextlib import nullcontext
import json
from pathlib import Path
import secrets
import tempfile
from native_shelf_trial import validate_plan,digest
from secure_shelf_experiment import canonical,Receipt
from secure_native_session import project_lock
from secure_weread_session import MacKeychain,ACCOUNT,StoreError

SERVICE='org.codex.weread.goal-native-shelf-trial'


class NativeShelfTrialStore:
    service=SERVICE
    lock_prefix='codex-native-shelf-'
    validator=staticmethod(validate_plan)
    def __init__(self,backend=None,lock=None):
        self.backend=backend if backend is not None else MacKeychain(service=self.service,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/(self.lock_prefix+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)

    def _load(self):
        raw=self.backend.load()
        if raw is None:return None,None
        try:
            value=json.loads(raw)
            if (not isinstance(raw,bytes) or not 0<len(raw)<=8192 or set(value)!={'schema','scope','attempt','reserved_posts','plan'}
                    or type(value['schema']) is not int or value['schema']!=1 or value['scope']!=ACCOUNT
                    or type(value['reserved_posts']) is not int or value['reserved_posts']!=2
                    or not isinstance(value['attempt'],str) or len(value['attempt'])!=32
                    or any(c not in 'abcdef0123456789' for c in value['attempt'])):raise ValueError()
            self.validator(value['plan']);return value,raw
        except (ValueError,TypeError,KeyError,UnicodeError):raise StoreError('native_shelf/intent_invalid') from None

    def read(self):
        with self.lock():
            value,raw=self._load();return value,Receipt(raw) if raw else None

    def pending(self):return self.read()[0] is not None

    def reserve(self,plan):
        self.validator(plan)
        with self.lock():
            if self._load()[0] is not None:raise StoreError('native_shelf/pending')
            raw=canonical(dict(schema=1,scope=ACCOUNT,attempt=secrets.token_hex(16),reserved_posts=2,plan=plan))
            self.backend.save(raw)
            if self.backend.load()!=raw:raise StoreError('native_shelf/intent_readback')
            self._load();return Receipt(raw)

    def owns(self,receipt,plan):
        with self.lock():
            value,raw=self._load()
            return isinstance(receipt,Receipt) and raw==receipt.pending and value is not None and digest(value['plan'])==digest(plan)

    def finish(self,receipt,*,restored_verified=False):
        if restored_verified is not True:raise StoreError('native_shelf/proof')
        with self.lock():
            if not isinstance(receipt,Receipt) or self._load()[1]!=receipt.pending:raise StoreError('native_shelf/replaced')
            self.backend.delete()
            if self.backend.load() is not None:raise StoreError('native_shelf/cleanup')
