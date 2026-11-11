"""Durable two-write reservation with no pending replay and no source text."""
from contextlib import nullcontext
from dataclasses import dataclass
import json
from pathlib import Path
import secrets
import tempfile
from annotation_experiment_model import canonical,valid_key
from highlight_trial_model import validate_plan
from secure_native_session import project_lock
from secure_weread_session import MacKeychain,ACCOUNT,StoreError

SERVICE='org.codex.weread.goal-highlight-trial'
NATIVE_SERVICE='org.codex.weread.goal-native-highlight-trial'


@dataclass(frozen=True,repr=False)
class Receipt:
    raw:bytes


class HighlightTrialStore:
    def __init__(self,backend=None,lock=None,*,native=False):
        if type(native) is not bool:raise ValueError('highlight_intent_kind')
        self.native=native
        self.backend=backend if backend is not None else MacKeychain(service=NATIVE_SERVICE if native else SERVICE,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/(('codex-native-highlight-' if native else 'codex-highlight-')+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)

    def _load(self):
        raw=self.backend.load()
        if raw is None:return None,None
        try:
            if not isinstance(raw,bytes) or not 0<len(raw)<=8192:raise ValueError()
            v=json.loads(raw)
            if (set(v)!={'schema','scope','attempt','phase','plan','target','reserved_posts'}
                    or type(v['schema']) is not int or v['schema']!=1 or v['scope']!=ACCOUNT
                    or v['phase'] not in ('create_pending','created','delete_pending','verified')
                    or type(v['reserved_posts']) is not int or v['reserved_posts']!=2
                    or not isinstance(v['attempt'],str) or len(v['attempt'])!=32
                    or any(c not in '0123456789abcdef' for c in v['attempt'])):raise ValueError()
            validate_plan(v['plan'],native=self.native);target=v['target']
            if v['phase']=='create_pending':
                if target is not None:raise ValueError()
            elif (not isinstance(target,dict) or set(target)!={'id','sha256'} or not valid_key(target['id'])
                    or not isinstance(target['sha256'],str) or len(target['sha256'])!=64
                    or any(c not in '0123456789abcdef' for c in target['sha256'])):raise ValueError()
            return v,raw
        except (TypeError,ValueError,KeyError):raise StoreError('highlight_intent_invalid') from None

    def _write(self,v):
        raw=canonical(v)
        if len(raw)>8192:raise StoreError('highlight_intent_invalid')
        self.backend.save(raw)
        if self.backend.load()!=raw:raise StoreError('highlight_intent_readback')
        self._load();return Receipt(raw)

    def read(self):
        with self.lock():
            v,raw=self._load();return v,Receipt(raw) if raw else None

    def reserve(self,plan):
        validate_plan(plan,native=self.native)
        with self.lock():
            if self._load()[0] is not None:raise StoreError('highlight_intent_exists')
            return self._write(dict(schema=1,scope=ACCOUNT,attempt=secrets.token_hex(16),phase='create_pending',plan=plan,target=None,reserved_posts=2))

    def advance(self,receipt,phase,*,target=None):
        with self.lock():
            v,raw=self._load()
            expected={'created':'create_pending','delete_pending':'created','verified':'delete_pending'}.get(phase)
            if (not isinstance(receipt,Receipt) or raw!=receipt.raw or not expected or v is None or v['phase']!=expected):raise StoreError('highlight_intent_replaced')
            if phase=='created':
                if (not isinstance(target,dict) or set(target)!={'id','sha256'} or not valid_key(target['id'])
                        or not isinstance(target['sha256'],str) or len(target['sha256'])!=64
                        or any(c not in '0123456789abcdef' for c in target['sha256'])):raise StoreError('highlight_intent_target')
                v['target']=target
            elif target is not None:raise StoreError('highlight_intent_target')
            v['phase']=phase;return self._write(v)

    def owns(self,receipt,phase):
        with self.lock():
            v,raw=self._load()
            return isinstance(receipt,Receipt) and receipt.raw==raw and v is not None and v['phase']==phase

    def finish(self,receipt):
        with self.lock():
            v,raw=self._load()
            if not isinstance(receipt,Receipt) or raw!=receipt.raw or v is None or v['phase']!='verified':raise StoreError('highlight_intent_unverified')
            self.backend.delete()
            if self.backend.load() is not None:raise StoreError('highlight_intent_cleanup')
