"""Project-scoped native credentials in macOS Keychain, until goal cleanup.

This separate item never overwrites the Web Cookie session. Credentials are
only accepted after a verified owner/shelf check and never passed in argv.
"""
from datetime import datetime, timezone
import json
import re

from secure_weread_session import ACCOUNT, MAX_BYTES, MacKeychain, StoreError

SERVICE='org.codex.weread.goal-native-validation'


def validate(payload,expected_vid):
    if (not isinstance(payload,dict) or set(payload)!={'schema','scope','kind','created_at','credentials'}
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
    return payload


class NativeSessionStore:
    def __init__(self,backend=None):
        self.backend=backend if backend is not None else MacKeychain(service=SERVICE,account=ACCOUNT)

    def save(self,credentials,expected_vid,*,verified=False):
        if verified is not True:raise StoreError('native_verified_shelf_required')
        payload=validate(dict(schema=1,scope=ACCOUNT,kind='eink',created_at=datetime.now(timezone.utc).isoformat(),credentials=credentials),expected_vid)
        data=json.dumps(payload,separators=(',',':')).encode()
        if len(data)>MAX_BYTES:raise StoreError('native_session_invalid')
        self.backend.save(data)
        if self.backend.load()!=data:raise StoreError('native_keychain_readback_mismatch')

    def load(self,expected_vid):
        data=self.backend.load()
        if data is None:raise StoreError('native_saved_session_missing')
        try:
            if not isinstance(data,bytes) or not 0<len(data)<=MAX_BYTES:raise StoreError('native_session_invalid')
            return validate(json.loads(data),expected_vid)['credentials']
        except (ValueError,TypeError,UnicodeError):raise StoreError('native_session_invalid') from None

    def delete(self):
        return self.backend.delete()
