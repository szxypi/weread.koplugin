"""Durable three-POST development experiment, separate from login storage."""
from contextlib import nullcontext
from dataclasses import dataclass
from datetime import datetime,timezone
import json
from pathlib import Path
import re
import secrets
import tempfile

from annotation_experiment_model import canonical,validate_plan,valid_key,fingerprint
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,MacKeychain,StoreError

SERVICE='org.codex.weread.goal-annotation-experiment'
PHASES={'prepared':(0,False),'create_pending':(1,False),'created':(1,True),'edit_pending':(2,True),
        'edited':(2,True),'delete_pending':(3,True),'deleted':(3,True),'verified':(3,True)}
NEXT={'prepared':'create_pending','create_pending':'created','created':'edit_pending','edit_pending':'edited',
      'edited':'delete_pending','delete_pending':'deleted','deleted':'verified'}
FIELDS={'schema','scope','attempt','created_at','maximum_posts','phase','posts','plan','created_id','record_sha256'}


@dataclass(frozen=True,repr=False)
class Receipt:
    raw:bytes


class AnnotationExperimentStore:
    def __init__(self,backend=None,lock=None):
        self.backend=backend if backend is not None else MacKeychain(service=SERVICE,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/('codex-annotation-weread-'+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)

    def _load(self):
        raw=self.backend.load()
        if raw is None:return None,None
        try:
            if not isinstance(raw,bytes) or not 0<len(raw)<=8192:raise ValueError()
            value=json.loads(raw)
            if (not isinstance(value,dict) or set(value)!=FIELDS or type(value['schema']) is not int or value['schema']!=1
                    or value['scope']!=ACCOUNT or type(value['maximum_posts']) is not int or value['maximum_posts']!=3
                    or not isinstance(value['phase'],str) or value['phase'] not in PHASES
                    or type(value['posts']) is not int or value['posts']!=PHASES[value['phase']][0]
                    or not isinstance(value['attempt'],str) or not re.fullmatch('[a-f0-9]{32}',value['attempt'])
                    or not isinstance(value['created_at'],str) or not 1<=len(value['created_at'])<=64):raise ValueError()
            validate_plan(value['plan'])
            if PHASES[value['phase']][1]:
                if not valid_key(value['created_id']) or not isinstance(value['record_sha256'],str) or not re.fullmatch('[a-f0-9]{64}',value['record_sha256']):raise ValueError()
            elif value['created_id'] is not None or value['record_sha256'] is not None:raise ValueError()
            return value,raw
        except (ValueError,TypeError,UnicodeError,KeyError):raise StoreError('annotation_intent_invalid') from None

    def _write(self,value):
        raw=canonical(value)
        if len(raw)>8192:raise StoreError('annotation_intent_invalid')
        self.backend.save(raw)
        if self.backend.load()!=raw:raise StoreError('annotation_intent_readback_failed')
        self._load();return Receipt(raw)

    def pending(self):
        with self.lock():return self._load()[0] is not None

    def read(self):
        with self.lock():
            value,raw=self._load();return value,Receipt(raw) if raw else None

    def prepare(self,plan):
        validate_plan(plan)
        with self.lock():
            if self._load()[0] is not None:raise StoreError('annotation_intent_exists')
            return self._write(dict(schema=1,scope=ACCOUNT,attempt=secrets.token_hex(16),created_at=datetime.now(timezone.utc).isoformat(),
                maximum_posts=3,phase='prepared',posts=0,plan=plan,created_id=None,record_sha256=None))

    def advance(self,receipt,expected,following,*,created_id=None,record_sha256=None):
        with self.lock():
            value,raw=self._load()
            if not isinstance(receipt,Receipt) or raw!=receipt.raw or value is None:raise StoreError('annotation_intent_replaced')
            if value['phase']!=expected or NEXT.get(expected)!=following:raise StoreError('annotation_phase_blocked')
            if following=='created':
                if not valid_key(created_id) or not isinstance(record_sha256,str) or not re.fullmatch('[a-f0-9]{64}',record_sha256):raise StoreError('annotation_record_unverified')
                value.update(created_id=created_id,record_sha256=record_sha256)
            elif following=='edited':
                if created_id!=value['created_id'] or not isinstance(record_sha256,str) or not re.fullmatch('[a-f0-9]{64}',record_sha256):raise StoreError('annotation_record_unverified')
                value['record_sha256']=record_sha256
            elif created_id is not None or record_sha256 is not None:raise StoreError('annotation_phase_blocked')
            value['phase'],value['posts']=following,PHASES[following][0]
            return self._write(value)

    def owns(self,receipt,phase=None):
        with self.lock():
            value,raw=self._load()
            return isinstance(receipt,Receipt) and raw==receipt.raw and value is not None and (phase is None or value['phase']==phase)

    def finish(self,receipt,*,discard_prepared=False):
        with self.lock():
            value,raw=self._load()
            if not isinstance(receipt,Receipt) or raw!=receipt.raw or value is None:raise StoreError('annotation_intent_replaced')
            if value['phase']!=('prepared' if discard_prepared is True else 'verified'):raise StoreError('annotation_resolution_unverified')
            self.backend.delete()
            if self.backend.load() is not None:raise StoreError('annotation_intent_cleanup_failed')
