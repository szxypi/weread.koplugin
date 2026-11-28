"""One pending bounded experiment, separate from both credential entries.

Only coordinates and hashes are stored in the temporary Keychain item. No
tokens, cookies, titles, source text or request bodies. Unknown results stay
pending; this module has no network or automatic resume/write operation.
"""
from contextlib import nullcontext
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import secrets
import tempfile

from secure_weread_session import ACCOUNT, MacKeychain, StoreError
from secure_native_session import project_lock

SERVICE='org.codex.weread.goal-position-experiment'
MAX_BYTES=8192
PLAN_FIELDS={'owner','book_id','chapter_uid','chapter_idx','baseline_offset','probe_offset','raw_percent',
             'raw_source_sha256','baseline_summary_sha256','probe_summary_sha256'}


def canonical(value):return json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False).encode()


def validate_plan(value):
    if not isinstance(value,dict) or set(value)!=PLAN_FIELDS:raise StoreError('position_plan_invalid')
    for key in ('owner','book_id','chapter_uid'):
        if not isinstance(value[key],str) or not re.fullmatch(r'[1-9][0-9]{0,19}',value[key]):raise StoreError('position_plan_invalid')
    for key,maximum in (('chapter_idx',1000000),('baseline_offset',2147483646),('probe_offset',2147483647),('raw_percent',100)):
        if type(value[key]) is not int or not 0<=value[key]<=maximum:raise StoreError('position_plan_invalid')
    if value['probe_offset']!=value['baseline_offset']+1:raise StoreError('position_plan_invalid')
    for key in ('raw_source_sha256','baseline_summary_sha256','probe_summary_sha256'):
        if not isinstance(value[key],str) or not re.fullmatch('[0-9a-f]{64}',value[key]):raise StoreError('position_plan_invalid')
    return value


def binding(owner,plan,source_sha256):
    first,last=plan['baseline'],plan['target']
    if (last is None or str(first['book_id'])!=str(plan['book_id'])
            or any(first[k]!=last[k] for k in ('book_id','chapter_uid','chapter_idx','raw_percent'))):
        raise StoreError('position_plan_invalid')
    value=dict(owner=owner,book_id=str(plan['book_id']),chapter_uid=str(first['chapter_uid']),chapter_idx=first['chapter_idx'],
               baseline_offset=first['chapter_offset'],probe_offset=last['chapter_offset'],raw_percent=first['raw_percent'],
               raw_source_sha256=source_sha256,baseline_summary_sha256=hashlib.sha256(first['summary'].encode()).hexdigest(),
               probe_summary_sha256=hashlib.sha256(last['summary'].encode()).hexdigest())
    return validate_plan(value)


def fingerprint(value):return hashlib.sha256(canonical(validate_plan(value))).hexdigest()


@dataclass(frozen=True,repr=False)
class ExperimentReceipt:
    pending: bytes


class ExperimentStore:
    def __init__(self,backend=None,lock=None):
        self.backend=backend if backend is not None else MacKeychain(service=SERVICE,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/('codex-position-weread-'+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)

    def _load(self):
        raw=self.backend.load()
        if raw is None:return None,None
        try:
            if not isinstance(raw,bytes) or not 0<len(raw)<=MAX_BYTES:raise ValueError()
            value=json.loads(raw)
            if (not isinstance(value,dict) or set(value)!={'schema','scope','attempt','started_at','maximum_posts','plan'}
                    or type(value['schema']) is not int or value['schema']!=1 or value['scope']!=ACCOUNT
                    or value['maximum_posts']!=4 or type(value['maximum_posts']) is not int
                    or not isinstance(value['attempt'],str) or not re.fullmatch('[0-9a-f]{32}',value['attempt'])
                    or not isinstance(value['started_at'],str) or not 1<=len(value['started_at'])<=64):raise ValueError()
            validate_plan(value['plan'])
            return value,raw
        except (ValueError,TypeError,UnicodeError):raise StoreError('position_intent_invalid') from None

    def pending(self):
        with self.lock():return self._load()[0] is not None

    def begin(self,plan):
        validate_plan(plan)
        with self.lock():
            if self._load()[0] is not None:raise StoreError('position_experiment_unconfirmed')
            value=dict(schema=1,scope=ACCOUNT,attempt=secrets.token_hex(16),started_at=datetime.now(timezone.utc).isoformat(),maximum_posts=4,plan=plan)
            raw=canonical(value)
            if len(raw)>MAX_BYTES:raise StoreError('position_intent_invalid')
            self.backend.save(raw)
            if self.backend.load()!=raw:raise StoreError('position_intent_readback_failed')
            return ExperimentReceipt(raw)

    def finish(self,receipt,*,restored_verified=False,not_dispatched=False):
        if (not isinstance(receipt,ExperimentReceipt) or (restored_verified is not True and not_dispatched is not True)
                or restored_verified is True and not_dispatched is True):raise StoreError('position_resolution_proof_required')
        with self.lock():
            _value,raw=self._load()
            if raw!=receipt.pending:raise StoreError('position_intent_replaced')
            self.backend.delete()
            if self.backend.load() is not None:raise StoreError('position_intent_cleanup_unverified')
