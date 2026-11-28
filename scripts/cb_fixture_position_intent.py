"""Durably reserve a single fixture-only four-request experiment; no replay."""
from contextlib import nullcontext
import hashlib
import re
from pathlib import Path
import tempfile
from cb_fixture_position import canonical
from verify_cb_progress import cb_id
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,MacKeychain,StoreError

SERVICE='org.codex.weread.cb-fixture-position-v1'


def digest(value):return hashlib.sha256(value.encode()).hexdigest()


class Intent:
    def __init__(self,backend=None,lock=None):
        self.backend=backend if backend is not None else MacKeychain(service=SERVICE,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/('codex-cb-fixture-position-'+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)

    def reserve(self,owner,book,attempt):
        if (not isinstance(owner,str) or re.fullmatch(r'[1-9][0-9]{0,19}',owner) is None or not cb_id(book)
                or not isinstance(attempt,str) or re.fullmatch('[a-f0-9]{32}',attempt) is None):raise StoreError('cb_fixture/invalid')
        value=dict(schema=1,scope=ACCOUNT,phase='reserved',owner=digest(owner),book=digest(book),attempt=attempt,slots=4)
        raw=canonical(value).encode()
        with self.lock():
            if self.backend.load() is not None:raise StoreError('cb_fixture/already_reserved')
            self.backend.save(raw)
            if self.backend.load()!=raw:raise StoreError('cb_fixture/readback')
        return raw

    def verify(self,receipt,owner,book,attempt):
        value=dict(schema=1,scope=ACCOUNT,phase='reserved',owner=digest(owner),book=digest(book),attempt=attempt,slots=4)
        raw=canonical(value).encode()
        with self.lock():return isinstance(receipt,bytes) and receipt==raw and self.backend.load()==raw
