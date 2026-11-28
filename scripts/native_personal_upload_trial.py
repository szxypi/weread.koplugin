"""Durable no-replay intent for an isolated native synthetic upload trial."""
from contextlib import nullcontext
from dataclasses import dataclass
import json,re,secrets,tempfile
from pathlib import Path
from personal_upload_trial import validate,valid_book
from secure_native_session import project_lock
from secure_shelf_experiment import canonical
from secure_weread_session import ACCOUNT,MacKeychain,StoreError

SERVICE='org.codex.weread.goal-native-personal-upload-trial-v1'
STEPS={'reserved':'launched','launched':'imported','imported':'cleanup_pending','cleanup_pending':'restored'}


@dataclass(frozen=True,repr=False)
class Receipt:raw:bytes


class Journal:
    def __init__(self,backend=None,lock=None,validator=None):
        self.backend=backend if backend is not None else MacKeychain(service=SERVICE,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/('codex-native-personal-upload-'+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)
        self.validate=validator or validate
    def _read(self):
        raw=self.backend.load()
        if raw is None:return None,None
        try:
            value=json.loads(raw)
            if (not isinstance(raw,bytes) or not 0<len(raw)<=8192 or not isinstance(value,dict)
                    or set(value)!={'schema','scope','attempt','phase','plan','target'}
                    or type(value['schema']) is not int or value['schema']!=1 or value['scope']!=ACCOUNT
                    or not isinstance(value['attempt'],str) or re.fullmatch('[a-f0-9]{32}',value['attempt']) is None
                    or value['phase'] not in ('reserved','launched','imported','cleanup_pending','restored')):raise ValueError()
            self.validate(value['plan'])
            if value['phase'] in ('imported','cleanup_pending','restored'):
                if not valid_book(value['target']):raise ValueError()
            elif value['target'] is not None:raise ValueError()
            return value,raw
        except (ValueError,KeyError,TypeError,UnicodeError):raise StoreError('native_personal_upload/journal_invalid') from None
    def read(self):
        with self.lock():
            value,raw=self._read();return value,Receipt(raw) if raw else None
    def reserve(self,plan):
        self.validate(plan)
        with self.lock():
            if self._read()[0] is not None:raise StoreError('native_personal_upload/already_reserved')
            raw=canonical(dict(schema=1,scope=ACCOUNT,attempt=secrets.token_hex(16),phase='reserved',plan=plan,target=None))
            self.backend.save(raw)
            if self.backend.load()!=raw:raise StoreError('native_personal_upload/readback')
            self._read();return Receipt(raw)
    def advance(self,receipt,phase,*,target=None):
        with self.lock():
            value,raw=self._read()
            if (not isinstance(receipt,Receipt) or value is None or raw!=receipt.raw or STEPS.get(value['phase'])!=phase
                    or (phase=='imported')!=(target is not None) or target is not None and not valid_book(target)):
                raise StoreError('native_personal_upload/stale')
            if target is not None:value['target']=target
            value['phase']=phase;updated=canonical(value);self.backend.save(updated)
            if self.backend.load()!=updated:raise StoreError('native_personal_upload/readback')
            self._read();return Receipt(updated)
