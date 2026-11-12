"""Two one-shot slots, monotonic claims, retained TXT protocol tombstone."""
from contextlib import nullcontext
import json
from pathlib import Path
import re
import secrets
import tempfile
from secure_weread_session import MacKeychain,ACCOUNT,StoreError
from secure_native_session import project_lock
from secure_shelf_experiment import canonical,Receipt
from txt_full_summary import PROTOCOL,HASHES

PHASES={'prepared':0,'enter_pending':1,'enter_verified':1,'same_pending':2,'retired':2,'aborted':0,'closed_enter_unverified':1,'closed_same_unverified':2}


def validate_plan(value):
    if not isinstance(value,dict) or set(value)!=HASHES|{'protocol'} or value['protocol']!=PROTOCOL:raise StoreError('txt_full/plan')
    if any(not isinstance(value[k],str) or not re.fullmatch('[a-f0-9]{64}',value[k]) for k in HASHES):raise StoreError('txt_full/plan')


class TxtFullSummaryStore:
    service='org.codex.weread.goal-txt-full-summary-v1'
    def __init__(self,backend=None,lock=None):
        self.backend=backend if backend is not None else MacKeychain(service=self.service,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/('codex-txt-full-summary-'+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)
    def _load(self):
        raw=self.backend.load()
        if raw is None:return None,None
        try:
            value=json.loads(raw)
            if (not isinstance(raw,bytes) or len(raw)>8192 or not isinstance(value,dict)
                    or set(value)!={'schema','scope','attempt','phase','posts','plan'} or type(value['schema']) is not int or value['schema']!=1
                    or value['scope']!=ACCOUNT or value['phase'] not in PHASES or type(value['posts']) is not int
                    or value['posts']!=PHASES[value['phase']] or not isinstance(value['attempt'],str)
                    or not re.fullmatch('[a-f0-9]{32}',value['attempt'])):raise ValueError()
            validate_plan(value['plan']);return value,raw
        except Exception:raise StoreError('txt_full/intent_invalid') from None
    def read(self):
        with self.lock():
            value,raw=self._load();return value,Receipt(raw) if raw else None
    def pending(self):
        value,_r=self.read();return value is not None and value['phase'] not in ('retired','aborted','closed_enter_unverified','closed_same_unverified')
    def _write(self,value):
        raw=canonical(value);self.backend.save(raw)
        if self.backend.load()!=raw:raise StoreError('txt_full/readback')
        self._load();return Receipt(raw)
    def reserve(self,plan):
        validate_plan(plan)
        with self.lock():
            if self._load()[0] is not None:raise StoreError('txt_full/consumed')
            return self._write(dict(schema=1,scope=ACCOUNT,attempt=secrets.token_hex(16),phase='prepared',posts=0,plan=plan))
    def advance(self,receipt,before,after):
        if (before,after) not in {('prepared','enter_pending'),('enter_pending','enter_verified'),('enter_verified','same_pending'),('same_pending','retired'),('prepared','aborted'),('enter_pending','closed_enter_unverified'),('same_pending','closed_same_unverified')}:raise StoreError('txt_full/phase')
        with self.lock():
            value,raw=self._load()
            if not isinstance(receipt,Receipt) or raw!=receipt.pending or value['phase']!=before:raise StoreError('txt_full/replaced')
            value['phase'],value['posts']=after,PHASES[after];return self._write(value)
