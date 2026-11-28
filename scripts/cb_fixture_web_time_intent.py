"""One durable, non-repeatable two-second slot for a bound synthetic CB book."""
from contextlib import nullcontext
import hashlib
from pathlib import Path
import re
import tempfile

from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,MacKeychain,StoreError
from verify_cb_progress import cb_id
from verify_position_roundtrip import canonical

SERVICE='org.codex.weread.cb-web-time-fixture-v1'


def digest(value):return hashlib.sha256(value.encode()).hexdigest()


class Intent:
    def __init__(self,backend=None,lock=None):
        self.backend=backend if backend is not None else MacKeychain(service=SERVICE,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/('codex-cb-web-time-fixture-'+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)

    def reserve(self,owner,book,attempt,baseline):
        if (not isinstance(owner,str) or not re.fullmatch('[1-9][0-9]{0,19}',owner) or not cb_id(book)
                or not isinstance(attempt,str) or not re.fullmatch('[a-f0-9]{32}',attempt)
                or not isinstance(baseline,str) or not re.fullmatch('[a-f0-9]{64}',baseline)):
            raise StoreError('cb_web_time/invalid')
        record=dict(schema=1,scope=ACCOUNT,owner=digest(owner),book=digest(book),attempt=attempt,baseline=baseline,claimed=False)
        raw=canonical(record).encode()
        with self.lock():
            if self.backend.load() is not None:raise StoreError('cb_web_time/already_reserved')
            self.backend.save(raw)
            if self.backend.load()!=raw:raise StoreError('cb_web_time/readback')
        return record

    def claim(self,record):
        with self.lock():
            if self.backend.load()!=canonical(record).encode() or record.get('claimed') is not False:
                raise StoreError('cb_web_time/claim')
            updated=dict(record,claimed=True);raw=canonical(updated).encode();self.backend.save(raw)
            if self.backend.load()!=raw:raise StoreError('cb_web_time/readback')
            record.update(updated);return raw

    def verify(self,record,receipt):
        with self.lock():
            return record.get('claimed') is True and isinstance(receipt,bytes) and receipt==canonical(record).encode() and self.backend.load()==receipt
