"""Distinct four-slot reservation; no pending phase can be replayed."""
from contextlib import nullcontext
import json
from pathlib import Path
import secrets
import tempfile
from annotation_experiment_model import canonical
from mark_style_trial_model import PHASES,validate_plan,target_valid
from secure_highlight_trial import Receipt
from secure_native_session import project_lock
from secure_weread_session import MacKeychain,ACCOUNT,StoreError

SERVICE='org.codex.weread.goal-mark-style-trial'
NATIVE_SERVICE='org.codex.weread.goal-native-mark-style-trial'


class MarkStyleTrialStore:
    def __init__(self,backend=None,lock=None,*,native=False):
        if type(native) is not bool:raise ValueError('mark_style/intent_kind')
        self.native=native
        self.backend=backend if backend is not None else MacKeychain(service=NATIVE_SERVICE if native else SERVICE,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/(('codex-native-mark-style-' if native else 'codex-mark-style-')+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)

    def _load(self):
        raw=self.backend.load()
        if raw is None:return None,None
        try:
            if not isinstance(raw,bytes) or not 0<len(raw)<=8192:raise ValueError()
            v=json.loads(raw)
            if (set(v)!={'schema','scope','attempt','phase','plan','target','reserved_posts'}
                    or type(v['schema']) is not int or v['schema']!=1 or v['scope']!=ACCOUNT
                    or v['phase'] not in PHASES or type(v['reserved_posts']) is not int or v['reserved_posts']!=4
                    or not isinstance(v['attempt'],str) or len(v['attempt'])!=32
                    or any(c not in '0123456789abcdef' for c in v['attempt'])):raise ValueError()
            validate_plan(v['plan'],native=self.native)
            if v['phase']=='create_pending':
                if v['target'] is not None:raise ValueError()
            elif not target_valid(v['target']):raise ValueError()
            return v,raw
        except (ValueError,KeyError,TypeError):raise StoreError('mark_style/intent_invalid') from None

    def read(self):
        with self.lock():
            v,raw=self._load();return v,Receipt(raw) if raw else None

    def _write(self,value):
        raw=canonical(value)
        if len(raw)>8192:raise StoreError('mark_style/intent_invalid')
        self.backend.save(raw)
        if self.backend.load()!=raw:raise StoreError('mark_style/intent_readback')
        self._load();return Receipt(raw)

    def reserve(self,plan):
        validate_plan(plan,native=self.native)
        with self.lock():
            if self._load()[0] is not None:raise StoreError('mark_style/intent_exists')
            return self._write(dict(schema=1,scope=ACCOUNT,attempt=secrets.token_hex(16),phase=PHASES[0],plan=plan,target=None,reserved_posts=4))

    def advance(self,receipt,phase,*,target=None):
        with self.lock():
            v,raw=self._load()
            if (not isinstance(receipt,Receipt) or raw!=receipt.raw or v is None or phase not in PHASES
                    or PHASES.index(phase)!=PHASES.index(v['phase'])+1):raise StoreError('mark_style/replaced')
            if phase in ('created','straight','wave'):
                if not target_valid(target) or v['target'] is not None and v['target']['id']!=target['id']:raise StoreError('mark_style/target')
                v['target']=target
            elif target is not None:raise StoreError('mark_style/target')
            v['phase']=phase;return self._write(v)

    def owns(self,receipt,phase):
        with self.lock():
            v,raw=self._load();return isinstance(receipt,Receipt) and raw==receipt.raw and v is not None and v['phase']==phase

    def finish(self,receipt):
        with self.lock():
            v,raw=self._load()
            if not isinstance(receipt,Receipt) or raw!=receipt.raw or v is None or v['phase']!='verified':raise StoreError('mark_style/unverified')
            self.backend.delete()
            if self.backend.load() is not None:raise StoreError('mark_style/cleanup')
