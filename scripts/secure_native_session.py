"""Project-scoped native credentials in macOS Keychain, until goal cleanup.

This separate item never overwrites the Web Cookie session. Credentials are
only accepted after a verified owner/shelf check and never passed in argv.
"""
from datetime import datetime, timezone
from contextlib import contextmanager,nullcontext
from dataclasses import dataclass
import json
import os
from pathlib import Path
import re
import secrets
import stat
import tempfile

from secure_weread_session import ACCOUNT, MAX_BYTES, MacKeychain, StoreError

SERVICE='org.codex.weread.goal-native-validation'


def validate(payload,expected_vid):
    fields={'schema','scope','kind','created_at','credentials'}
    if (not isinstance(payload,dict) or set(payload) not in (fields,fields|{'renewal'})
            or type(payload.get('schema')) is not int or payload['schema']!=1 or payload['scope']!=ACCOUNT or payload['kind']!='eink'):
        raise StoreError('native_session_invalid')
    credentials=payload['credentials']
    if not isinstance(credentials,dict) or set(credentials)!={'vid','accessToken','refreshToken','deviceId'}:
        raise StoreError('native_session_invalid')
    vid=credentials['vid']
    if not isinstance(vid,str) or not re.fullmatch(r'[1-9][0-9]{0,19}',vid) or vid!=expected_vid:
        raise StoreError('native_owner_mismatch')
    if not isinstance(credentials['deviceId'],str) or not re.fullmatch(r'eink334691225[0-9]{19}',credentials['deviceId']):
        raise StoreError('native_session_invalid')
    for key in ('accessToken','refreshToken'):
        value=credentials[key]
        if not isinstance(value,str) or not 8<=len(value)<=4096 or any(ord(c)<33 or ord(c)>126 or c in ';"\\' for c in value):
            raise StoreError('native_session_invalid')
    if not isinstance(payload['created_at'],str) or not 1<=len(payload['created_at'])<=64:
        raise StoreError('native_session_invalid')
    if 'renewal' in payload:
        renewal=payload['renewal']
        if (not isinstance(renewal,dict) or set(renewal)!={'attempt','started_at'} or not isinstance(renewal['attempt'],str)
                or not re.fullmatch(r'[0-9a-f]{32}',renewal['attempt']) or not isinstance(renewal['started_at'],str)
                or not 1<=len(renewal['started_at'])<=64):raise StoreError('native_session_invalid')
    return payload


@contextmanager
def project_lock(path=None):
    """Serialize this helper's Keychain writes; the lock file stays empty."""
    import fcntl
    path=path or Path(tempfile.gettempdir())/('codex-native-weread-'+ACCOUNT+'.lock')
    fd=None
    try:
        fd=os.open(path,os.O_CREAT|os.O_RDWR|getattr(os,'O_NOFOLLOW',0)|getattr(os,'O_CLOEXEC',0),0o600)
        info=os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid():raise StoreError('native_session_lock_unavailable')
        try:fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:raise StoreError('native_session_busy') from None
        yield
    except OSError:raise StoreError('native_session_lock_unavailable') from None
    finally:
        if fd is not None:os.close(fd)


@dataclass(frozen=True,repr=False)
class RenewalReceipt:
    owner: str
    pending: bytes


class NativeSessionStore:
    def __init__(self,backend=None,lock=None):
        self.backend=backend if backend is not None else MacKeychain(service=SERVICE,account=ACCOUNT)
        self.lock=lock or (project_lock if backend is None else nullcontext)

    def _write(self,payload,expected_vid):
        validate(payload,expected_vid)
        data=json.dumps(payload,separators=(',',':')).encode()
        if len(data)>MAX_BYTES:raise StoreError('native_session_invalid')
        self.backend.save(data)
        if self.backend.load()!=data:raise StoreError('native_keychain_readback_mismatch')
        return data

    def _read(self,expected_vid):
        data=self.backend.load()
        if data is None:raise StoreError('native_saved_session_missing')
        try:
            if not isinstance(data,bytes) or not 0<len(data)<=MAX_BYTES:raise StoreError('native_session_invalid')
            return validate(json.loads(data),expected_vid),data
        except (ValueError,TypeError,UnicodeError):raise StoreError('native_session_invalid') from None

    def save(self,credentials,expected_vid,*,verified=False):
        if verified is not True:raise StoreError('native_verified_shelf_required')
        with self.lock():
            self._write(dict(schema=1,scope=ACCOUNT,kind='eink',created_at=datetime.now(timezone.utc).isoformat(),credentials=credentials),expected_vid)

    def load(self,expected_vid):
        with self.lock():
            payload,_data=self._read(expected_vid)
            if 'renewal' in payload:raise StoreError('native_renewal_unconfirmed')
            return payload['credentials']

    def begin_renewal(self,expected_vid,expected_credentials=None):
        with self.lock():
            payload,_data=self._read(expected_vid)
            if 'renewal' in payload:raise StoreError('native_renewal_unconfirmed')
            if expected_credentials is not None and payload['credentials']!=expected_credentials:raise StoreError('native_renewal_replaced')
            payload['renewal']=dict(attempt=secrets.token_hex(16),started_at=datetime.now(timezone.utc).isoformat())
            pending=self._write(payload,expected_vid)
            return RenewalReceipt(expected_vid,pending),payload['credentials']

    def finish_renewal(self,receipt,credentials,*,verified=False):
        if not isinstance(receipt,RenewalReceipt) or verified is not True:raise StoreError('native_verified_shelf_required')
        with self.lock():
            payload,data=self._read(receipt.owner)
            if 'renewal' not in payload or data!=receipt.pending:raise StoreError('native_renewal_replaced')
            self._write(dict(schema=1,scope=ACCOUNT,kind='eink',created_at=datetime.now(timezone.utc).isoformat(),credentials=credentials),receipt.owner)

    def release_renewal(self,receipt,*,not_dispatched=False):
        if not isinstance(receipt,RenewalReceipt) or not_dispatched is not True:raise StoreError('native_pre_dispatch_proof_required')
        with self.lock():
            payload,data=self._read(receipt.owner)
            if 'renewal' not in payload or data!=receipt.pending:raise StoreError('native_renewal_replaced')
            payload.pop('renewal')
            self._write(payload,receipt.owner)

    def delete(self):
        with self.lock():return self.backend.delete()
