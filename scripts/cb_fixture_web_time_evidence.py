"""Single-use private pre-dispatch snapshot for a synthetic CB time test."""
import json
from contextlib import nullcontext
from pathlib import Path
import re
import tempfile
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,MacKeychain,StoreError
from verify_position_roundtrip import canonical

SERVICE='org.codex.weread.cb-web-time-fixture-baseline-v2'


class Evidence:
    def __init__(self,backend=None,lock=None):
        self.backend=backend if backend is not None else MacKeychain(service=SERVICE,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/('codex-cb-web-time-fixture-baseline-v2-'+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)
    def save(self,value):
        if (not isinstance(value,dict) or set(value)!={'schema','owner_sha256','book_sha256','attempt','baseline'}
                or type(value['schema']) is not int or value['schema']!=1
                or any(not isinstance(value[k],str) or not re.fullmatch('[a-f0-9]{64}',value[k]) for k in ('owner_sha256','book_sha256'))
                or not isinstance(value['attempt'],str) or not re.fullmatch('[a-f0-9]{32}',value['attempt'])
                or not isinstance(value['baseline'],dict) or set(value['baseline'])!={'source','position','updated_at','counters','stats','body'}):
            raise StoreError('cb_time_evidence/invalid')
        raw=canonical(value).encode()
        if len(raw)>65536:raise StoreError('cb_time_evidence/limit')
        with self.lock():
            if self.backend.load() is not None:raise StoreError('cb_time_evidence/occupied')
            self.backend.save(raw)
            if self.backend.load()!=raw or json.loads(raw)!=value:raise StoreError('cb_time_evidence/readback')
        return raw
