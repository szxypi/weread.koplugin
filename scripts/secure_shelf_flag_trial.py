"""Two separate one-shot private/restore slots. Consumed tombstone is retained."""
from contextlib import nullcontext
import json
from pathlib import Path
import secrets
import tempfile
from secure_weread_session import ACCOUNT,MacKeychain,StoreError
from secure_native_session import project_lock
from secure_shelf_experiment import canonical,Receipt
from shelf_flag_change_contract import valid_metadata

SERVICE='org.codex.weread.goal-private-flag-trial-v1'
PHASES={'prepared':0,'change_pending':1,'change_verified':1,'restore_pending':2,'retired':2}


def validate_plan(value):
    if not isinstance(value,dict) or set(value)!={'owner','grant_sha256','change','restore'}:raise StoreError('shelf_flag/plan')
    import re
    if not isinstance(value['owner'],str) or not re.fullmatch('[1-9][0-9]{0,19}',value['owner']) or not isinstance(value['grant_sha256'],str) or not re.fullmatch('[a-f0-9]{64}',value['grant_sha256']):raise StoreError('shelf_flag/plan')
    a,b=value['change'],value['restore']
    if not valid_metadata(a) or not valid_metadata(b) or a['kind']!='private' or b['kind']!='private' or a['book_id']!=b['book_id'] or a['before'] is not False or a['desired'] is not True or b['before'] is not True or b['desired'] is not False:raise StoreError('shelf_flag/plan')
    if a['before_hash']!=b['after_hash'] or a['after_hash']!=b['before_hash'] or a['position_hash']!=b['position_hash'] or a['before_hash']==a['after_hash']:raise StoreError('shelf_flag/plan')
    return value


class FlagTrialStore:
    def __init__(self,backend=None,lock=None):
        self.backend=backend or MacKeychain(service=SERVICE,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/('codex-private-flag-'+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)
    def _load(self):
        raw=self.backend.load()
        if raw is None:return None,None
        try:
            value=json.loads(raw)
            if not isinstance(raw,bytes) or len(raw)>8192 or set(value)!={'schema','scope','attempt','phase','posts','plan'} or value['schema']!=1 or type(value['schema']) is not int or value['scope']!=ACCOUNT or value['phase'] not in PHASES or type(value['posts']) is not int or value['posts']!=PHASES[value['phase']] or len(value['attempt'])!=32 or any(c not in 'abcdef0123456789' for c in value['attempt']):raise ValueError()
            validate_plan(value['plan']);return value,raw
        except Exception:raise StoreError('shelf_flag/intent_invalid') from None
    def read(self):
        with self.lock():
            value,raw=self._load();return value,Receipt(raw) if raw else None
    def pending(self):
        value,_receipt=self.read();return value is not None and value['phase']!='retired'
    def _write(self,value):
        raw=canonical(value);self.backend.save(raw)
        if self.backend.load()!=raw:raise StoreError('shelf_flag/intent_readback')
        self._load();return Receipt(raw)
    def reserve(self,plan):
        validate_plan(plan)
        with self.lock():
            if self._load()[0] is not None:raise StoreError('shelf_flag/already_reserved')
            return self._write(dict(schema=1,scope=ACCOUNT,attempt=secrets.token_hex(16),phase='prepared',posts=0,plan=plan))
    def advance(self,receipt,before,after):
        allowed={('prepared','change_pending'),('change_pending','change_verified'),('change_verified','restore_pending'),('restore_pending','retired')}
        if (before,after) not in allowed:raise StoreError('shelf_flag/phase')
        with self.lock():
            value,raw=self._load()
            if not isinstance(receipt,Receipt) or raw!=receipt.pending or value['phase']!=before:raise StoreError('shelf_flag/replaced')
            value['phase'],value['posts']=after,PHASES[after];return self._write(value)
