"""Single durable authorization for one direct-chapter time dispatch.

The claimed record is retained even on interruption; neither acknowledgement
nor verification re-enables sending. Private plan data stays in Keychain.
"""
from contextlib import nullcontext
import json
from pathlib import Path
import re
import secrets
import tempfile
import time

from annotation_experiment_model import canonical
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,MacKeychain,StoreError

SERVICE='org.codex.weread.direct-current-time-owner-trial-v1'


class Intent:
    def __init__(self,backend=None,lock=None):
        self.backend=backend if backend is not None else MacKeychain(service=SERVICE,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/('codex-direct-current-time-'+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)

    def _read(self):
        raw=self.backend.load()
        if raw is None:return None,None
        try:
            value=json.loads(raw)
            if (not isinstance(value,dict) or value.get('schema')!=1 or value.get('scope')!=ACCOUNT
                    or value.get('phase') not in ('claimed','acknowledged','verified')
                    or not isinstance(value.get('attempt'),str) or not re.fullmatch('[a-f0-9]{32}',value['attempt'])
                    or type(value.get('claimed_at')) is not int or not isinstance(value.get('plan'),dict)):
                raise ValueError()
            return value,raw
        except (ValueError,TypeError,UnicodeError):raise StoreError('direct_time/intent_invalid') from None

    def read(self):
        with self.lock():return self._read()

    def _write(self,value):
        raw=canonical(value)
        if not 1<=len(raw)<=60*1024:raise StoreError('direct_time/intent_size')
        self.backend.save(raw)
        if self.backend.load()!=raw:raise StoreError('direct_time/intent_readback')
        self._read();return raw

    def claim(self,plan,*,now=None):
        if not isinstance(plan,dict) or set(plan)!={'selection','record','body','baseline'}:
            raise StoreError('direct_time/invalid_plan')
        stamp=int(time.time()) if now is None else now
        if type(stamp) is not int or not 1<=stamp<=4102444800:raise StoreError('direct_time/invalid_clock')
        with self.lock():
            if self._read()!=(None,None):raise StoreError('direct_time/already_claimed')
            return self._write(dict(schema=1,scope=ACCOUNT,phase='claimed',attempt=secrets.token_hex(16),claimed_at=stamp,plan=plan))

    def advance(self,receipt,phase):
        if phase not in ('acknowledged','verified'):raise StoreError('direct_time/invalid_phase')
        with self.lock():
            value,raw=self._read()
            if not isinstance(receipt,bytes) or raw!=receipt or not value or \
                    (value['phase'],phase) not in (('claimed','acknowledged'),('acknowledged','verified')):
                raise StoreError('direct_time/intent_changed')
            value['phase']=phase;return self._write(value)
