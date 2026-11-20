"""Bind the sealed group inspection to the same native device after renewal.

The binding grants read-only inspection only. It cannot reopen a consumed
scope or authorize a group write, and does not store tokens or device IDs.
"""
from contextlib import nullcontext
import hashlib
import json
from pathlib import Path
import re
import tempfile

from cloud_group_contract import canonical, digest
from cloud_group_journal import validate as validate_journal
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT, MacKeychain, StoreError
from verify_eink_renewal import validate_credentials

SERVICE='org.codex.weread.goal-cloud-group-read-binding-v1'


def validate(value):
    if (not isinstance(value,dict) or set(value)!={'schema','scope','owner','journal_hash','device_hash'}
            or type(value['schema']) is not int or value['schema']!=1 or value['scope']!=ACCOUNT
            or not isinstance(value['owner'],str) or re.fullmatch('[1-9][0-9]{0,19}',value['owner']) is None):
        raise StoreError('cloud_group/binding_invalid')
    for key in ('journal_hash','device_hash'):
        if not isinstance(value[key],str) or re.fullmatch('[a-f0-9]{64}',value[key]) is None:
            raise StoreError('cloud_group/binding_invalid')
    return value


class Binding:
    def __init__(self,backend=None,lock=None):
        self.backend=backend if backend is not None else MacKeychain(service=SERVICE,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/('codex-cloud-group-binding-'+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)

    def _read(self):
        raw=self.backend.load()
        if raw is None:return None
        try:
            if not isinstance(raw,bytes) or not 0<len(raw)<=4096:raise ValueError()
            return validate(json.loads(raw))
        except (ValueError,KeyError,TypeError,UnicodeError):raise StoreError('cloud_group/binding_invalid') from None

    def read(self):
        with self.lock():return self._read()

    def bind(self,state,token,grant):
        validate_journal(state);validate_credentials(grant)
        if (state['phase']!='closed_unverified' or not isinstance(token,bytes) or token!=canonical(state)
                or state['owner']!=grant['vid'] or state['grant_hash']!=digest(grant)):
            raise StoreError('cloud_group/binding_scope')
        value=dict(schema=1,scope=ACCOUNT,owner=state['owner'],journal_hash=hashlib.sha256(token).hexdigest(),device_hash=digest(grant['deviceId']))
        with self.lock():
            if self._read() is not None:raise StoreError('cloud_group/binding_exists')
            raw=canonical(validate(value));self.backend.save(raw)
            if self.backend.load()!=raw or self._read()!=value:raise StoreError('cloud_group/binding_readback')
        return True

    def matches(self,state,token,grant):
        validate_journal(state);validate_credentials(grant)
        if not isinstance(token,bytes) or token!=canonical(state) or state['phase']!='closed_unverified':return False
        with self.lock():value=self._read()
        return bool(value and value['owner']==state['owner']==grant['vid']
            and value['journal_hash']==hashlib.sha256(token).hexdigest() and value['device_hash']==digest(grant['deviceId']))
