"""One durable palette reservation; each dispatch has its own atomic claim."""
from contextlib import nullcontext
import json
from pathlib import Path
import secrets
import tempfile
from annotation_experiment_model import canonical
from mark_color_model import STEPS,validate_plan,dispatch_hash
from mark_style_trial_model import target_valid
from secure_highlight_trial import Receipt
from secure_native_session import project_lock
from secure_weread_session import MacKeychain,ACCOUNT,StoreError

SERVICE='org.codex.weread.goal-mark-color-trial'


class MarkColorStore:
    def __init__(self,backend=None,lock=None):
        self.backend=backend if backend is not None else MacKeychain(service=SERVICE,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/('codex-mark-color-'+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)

    def _load(self):
        raw=self.backend.load()
        if raw is None:return None,None
        try:
            if not isinstance(raw,bytes) or not 0<len(raw)<=8192:raise ValueError()
            v=json.loads(raw)
            if (set(v)!={'schema','scope','attempt','plan','step','phase','target','dispatch_sha256','reserved_posts'}
                    or type(v['schema']) is not int or v['schema']!=1 or v['scope']!=ACCOUNT
                    or type(v['step']) is not int or not 0<=v['step']<=len(STEPS)
                    or type(v['reserved_posts']) is not int or v['reserved_posts']!=len(STEPS)
                    or not isinstance(v['attempt'],str) or len(v['attempt'])!=32 or any(c not in '0123456789abcdef' for c in v['attempt'])):raise ValueError()
            validate_plan(v['plan'])
            if v['step']==len(STEPS):
                if v['phase']!='complete' or v['target'] is not None or v['dispatch_sha256'] is not None:raise ValueError()
            else:
                expected=dispatch_hash(v['plan'],v['step'],v['target'])
                if v['phase'] not in ('pending','claimed') or v['dispatch_sha256']!=(expected if v['phase']=='claimed' else None):raise ValueError()
            return v,raw
        except (TypeError,ValueError,KeyError):raise StoreError('mark_color/intent_invalid') from None

    def _write(self,value):
        raw=canonical(value)
        if len(raw)>8192:raise StoreError('mark_color/intent_invalid')
        self.backend.save(raw)
        if self.backend.load()!=raw:raise StoreError('mark_color/intent_readback')
        self._load();return Receipt(raw)

    def read(self):
        with self.lock():
            value,raw=self._load();return value,Receipt(raw) if raw else None

    def reserve(self,plan):
        validate_plan(plan)
        with self.lock():
            if self._load()[0] is not None:raise StoreError('mark_color/intent_exists')
            return self._write(dict(schema=1,scope=ACCOUNT,attempt=secrets.token_hex(16),plan=plan,step=0,phase='pending',
                target=None,dispatch_sha256=None,reserved_posts=len(STEPS)))

    def claim(self,receipt,body_hash):
        with self.lock():
            v,raw=self._load()
            if (not isinstance(receipt,Receipt) or raw!=receipt.raw or v is None or v['phase']!='pending'
                    or body_hash!=dispatch_hash(v['plan'],v['step'],v['target'])):raise StoreError('mark_color/claim')
            v['phase']='claimed';v['dispatch_sha256']=body_hash;return self._write(v)

    def advance(self,receipt,target):
        with self.lock():
            v,raw=self._load()
            if not isinstance(receipt,Receipt) or raw!=receipt.raw or v is None or v['phase']!='claimed':raise StoreError('mark_color/replaced')
            operation,_color=STEPS[v['step']]
            if operation=='delete':
                if target is not None:raise StoreError('mark_color/target')
            elif not target_valid(target) or v['target'] is not None and v['target']['id']!=target['id']:raise StoreError('mark_color/target')
            v['step']+=1;v['phase']='complete' if v['step']==len(STEPS) else 'pending';v['target']=target;v['dispatch_sha256']=None
            return self._write(v)

    def finish(self,receipt):
        with self.lock():
            v,raw=self._load()
            if not isinstance(receipt,Receipt) or raw!=receipt.raw or v is None or v['phase']!='complete':raise StoreError('mark_color/unverified')
            self.backend.delete()
            if self.backend.load() is not None:raise StoreError('mark_color/cleanup')
