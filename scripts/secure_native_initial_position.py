"""One first-position request; typed original state is retained in Keychain."""
from contextlib import nullcontext
import json,re,secrets,tempfile
from pathlib import Path
from secure_weread_session import MacKeychain,ACCOUNT,StoreError
from secure_native_session import project_lock
from secure_shelf_experiment import canonical,Receipt
from native_initial_position import PROTOCOL,validate_plan

PHASES={'prepared':0,'pending':1,'acknowledged':1,'retired':1,'aborted':0,'closed_unverified':1}
TRANSITIONS={('prepared','pending'),('prepared','aborted'),('pending','acknowledged'),('acknowledged','retired'),
             ('pending','closed_unverified'),('acknowledged','closed_unverified')}


class NativeInitialPositionStore:
    service='org.codex.weread.goal-native-first-position-v1'
    protocol=PROTOCOL
    def __init__(self,backend=None,lock=None):
        self.backend=backend if backend is not None else MacKeychain(service=self.service,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/('codex-native-first-position-'+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)
    def _load(self):
        raw=self.backend.load()
        if raw is None:return None,None
        try:
            if not isinstance(raw,bytes) or not 0<len(raw)<=16384:raise ValueError()
            v=json.loads(raw)
            if (not isinstance(v,dict) or set(v)!={'schema','scope','attempt','phase','posts','plan'} or type(v['schema']) is not int or v['schema']!=1
                    or v['scope']!=ACCOUNT or v['phase'] not in PHASES or type(v['posts']) is not int or v['posts']!=PHASES[v['phase']]
                    or not isinstance(v['attempt'],str) or not re.fullmatch('[a-f0-9]{32}',v['attempt'])):raise ValueError()
            validate_plan(v['plan']);return v,raw
        except Exception:raise StoreError('initial_position/intent_invalid') from None
    def read(self):
        with self.lock():
            v,raw=self._load();return v,Receipt(raw) if raw else None
    def pending(self):
        v,_r=self.read();return v is not None and v['phase'] not in ('retired','aborted','closed_unverified')
    def _write(self,value):
        raw=canonical(value);self.backend.save(raw)
        if self.backend.load()!=raw:raise StoreError('initial_position/readback')
        self._load();return Receipt(raw)
    def reserve(self,plan):
        plan=validate_plan(plan)
        with self.lock():
            if self._load()[0] is not None:raise StoreError('initial_position/consumed')
            return self._write(dict(schema=1,scope=ACCOUNT,attempt=secrets.token_hex(16),phase='prepared',posts=0,plan=plan))
    def advance(self,receipt,before,after):
        if (before,after) not in TRANSITIONS:raise StoreError('initial_position/phase')
        with self.lock():
            v,raw=self._load()
            if not isinstance(receipt,Receipt) or raw!=receipt.pending or v['phase']!=before:raise StoreError('initial_position/replaced')
            v['phase'],v['posts']=after,PHASES[after];return self._write(v)
