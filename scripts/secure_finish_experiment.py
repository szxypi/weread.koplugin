"""One bounded completion-flag experiment, separate from login credentials."""
from contextlib import nullcontext
from dataclasses import dataclass
from datetime import datetime,timezone
import hashlib
import json
from pathlib import Path
import re
import secrets
import tempfile

from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,MacKeychain,StoreError

SERVICE='org.codex.weread.goal-finish-experiment'
FIELDS={'owner','book_id','before','shelf_flags_sha256','position_sha256','grant_sha256'}


def canonical(value):return json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False).encode()


def validate_plan(value):
    if not isinstance(value,dict) or set(value)!=FIELDS:raise StoreError('finish_plan_invalid')
    for key in ('owner','book_id'):
        if not isinstance(value[key],str) or not re.fullmatch('[1-9][0-9]{0,19}',value[key]):raise StoreError('finish_plan_invalid')
    if value['before'] is not False:raise StoreError('finish_plan_invalid')
    for key in ('shelf_flags_sha256','position_sha256','grant_sha256'):
        if not isinstance(value[key],str) or not re.fullmatch('[a-f0-9]{64}',value[key]):raise StoreError('finish_plan_invalid')
    return value


def fingerprint(value):return hashlib.sha256(canonical(validate_plan(value))).hexdigest()


@dataclass(frozen=True,repr=False)
class Receipt:
    pending:bytes


class FinishExperimentStore:
    def __init__(self,backend=None,lock=None):
        self.backend=backend if backend is not None else MacKeychain(service=SERVICE,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/('codex-finish-weread-'+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)

    def _load(self):
        raw=self.backend.load()
        if raw is None:return None,None
        try:
            if not isinstance(raw,bytes) or not 0<len(raw)<=4096:raise ValueError()
            value=json.loads(raw)
            if (not isinstance(value,dict) or set(value)!={'schema','scope','attempt','started_at','maximum_posts','plan'}
                    or type(value['schema']) is not int or value['schema']!=1 or value['scope']!=ACCOUNT
                    or type(value['maximum_posts']) is not int or value['maximum_posts']!=2
                    or not isinstance(value['attempt'],str) or not re.fullmatch('[a-f0-9]{32}',value['attempt'])
                    or not isinstance(value['started_at'],str) or not 1<=len(value['started_at'])<=64):raise ValueError()
            validate_plan(value['plan']);return value,raw
        except (ValueError,TypeError,UnicodeError):raise StoreError('finish_intent_invalid') from None

    def pending(self):
        with self.lock():return self._load()[0] is not None

    def begin(self,plan):
        validate_plan(plan)
        with self.lock():
            if self._load()[0] is not None:raise StoreError('finish_experiment_unconfirmed')
            raw=canonical(dict(schema=1,scope=ACCOUNT,attempt=secrets.token_hex(16),started_at=datetime.now(timezone.utc).isoformat(),maximum_posts=2,plan=plan))
            self.backend.save(raw)
            if self.backend.load()!=raw:raise StoreError('finish_intent_readback_failed')
            return Receipt(raw)

    def finish(self,receipt,*,restored_verified=False,not_dispatched=False):
        if (not isinstance(receipt,Receipt) or (restored_verified is not True and not_dispatched is not True)
                or restored_verified is True and not_dispatched is True):raise StoreError('finish_resolution_proof_required')
        with self.lock():
            if self._load()[1]!=receipt.pending:raise StoreError('finish_intent_replaced')
            self.backend.delete()
            if self.backend.load() is not None:raise StoreError('finish_intent_cleanup_unverified')
