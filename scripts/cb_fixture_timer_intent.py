"""Persistent, single-use reservation for one owned-fixture timer experiment."""
from contextlib import nullcontext
import hashlib
from pathlib import Path
import re
import tempfile

from secure_native_session import project_lock
from secure_weread_session import ACCOUNT, MacKeychain, StoreError
from verify_cb_progress import cb_id
from verify_position_roundtrip import canonical

SERVICE='org.codex.weread.cb-timer-fixture-ui-v1'
STAGES=('first_enter','first_manual','first_timer','second_enter','second_manual','second_timer')


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


class Intent:
    def __init__(self,backend=None,lock=None):
        self.backend=backend if backend is not None else MacKeychain(service=SERVICE,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/('codex-cb-timer-fixture-ui-'+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)

    def reserve(self,owner,book,attempt,baseline):
        if (not isinstance(owner,str) or not re.fullmatch('[1-9][0-9]{0,19}',owner) or not cb_id(book)
                or not isinstance(attempt,str) or not re.fullmatch('[a-f0-9]{32}',attempt)
                or not isinstance(baseline,str) or not re.fullmatch('[a-f0-9]{64}',baseline)):
            raise StoreError('cb_existing/invalid')
        value=dict(schema=1,scope=ACCOUNT,owner=digest(owner),book=digest(book),attempt=attempt,
                   baseline=baseline,claimed=0)
        raw=canonical(value).encode()
        with self.lock():
            if self.backend.load() is not None:raise StoreError('cb_existing/already_reserved')
            self.backend.save(raw)
            if self.backend.load()!=raw:raise StoreError('cb_existing/readback')
        return value

    def claim(self,value,stage):
        with self.lock():
            raw=canonical(value).encode()
            if (self.backend.load()!=raw or type(value.get('claimed')) is not int or value['claimed']>=len(STAGES)
                    or STAGES[value['claimed']]!=stage):raise StoreError('cb_existing/claim')
            updated=dict(value,claimed=value['claimed']+1)
            encoded=canonical(updated).encode();self.backend.save(encoded)
            if self.backend.load()!=encoded:raise StoreError('cb_existing/readback')
            value.update(updated)
            return encoded

    def verify(self,value,receipt):
        with self.lock():
            return isinstance(receipt,bytes) and receipt==canonical(value).encode() and self.backend.load()==receipt
