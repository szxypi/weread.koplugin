"""Permanent one-shot journal for the temporary empty-group protocol trial."""
from contextlib import nullcontext
import json
from pathlib import Path
import re
import secrets
import tempfile

from cloud_group_contract import canonical, digest, group_id, temporary_name
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT, MacKeychain, StoreError

SERVICE = 'org.codex.weread.goal-cloud-group-create-v1'
TRANSITIONS = {'prepared': {'create_claimed'}, 'create_claimed': {'created', 'rejected_unchanged'},
               'created': {'delete_claimed'}, 'delete_claimed': {'restored'}}


def validate(value):
    keys = {'schema', 'scope', 'attempt', 'owner', 'grant_hash', 'name', 'native_before', 'web_before', 'phase', 'group_id'}
    if not isinstance(value, dict) or set(value) != keys or type(value['schema']) is not int or value['schema'] != 1 or value['scope'] != ACCOUNT:
        raise StoreError('cloud_group/journal_invalid')
    if (not isinstance(value['attempt'], str) or not re.fullmatch('[a-f0-9]{32}', value['attempt'])
            or not isinstance(value['owner'], str) or not re.fullmatch('[1-9][0-9]{0,19}', value['owner'])
            or not temporary_name(value['name']) or value['phase'] not in set(TRANSITIONS) | {'restored', 'rejected_unchanged', 'closed_unverified'}):
        raise StoreError('cloud_group/journal_invalid')
    for key in ('grant_hash', 'native_before', 'web_before'):
        if not isinstance(value[key], str) or not re.fullmatch('[a-f0-9]{64}', value[key]):
            raise StoreError('cloud_group/journal_invalid')
    if value['phase'] in ('prepared', 'create_claimed', 'rejected_unchanged', 'closed_unverified'):
        if value['group_id'] is not None: raise StoreError('cloud_group/journal_invalid')
    elif not isinstance(value['group_id'], str) or not group_id(value['group_id']) or value['group_id'] == '1':
        raise StoreError('cloud_group/journal_invalid')
    return value


class Journal:
    def __init__(self, backend=None, lock=None):
        self.backend = backend if backend is not None else MacKeychain(service=SERVICE, account=ACCOUNT)
        path = Path(tempfile.gettempdir()) / ('codex-cloud-group-' + ACCOUNT + '.lock')
        self.lock = lock or ((lambda: project_lock(path)) if backend is None else nullcontext)

    def _read(self):
        raw = self.backend.load()
        if raw is None: return None, None
        try:
            if not isinstance(raw, bytes) or not 0 < len(raw) <= 8192: raise ValueError()
            return validate(json.loads(raw)), raw
        except (ValueError, TypeError, UnicodeError, KeyError):
            raise StoreError('cloud_group/journal_invalid') from None

    def read(self):
        with self.lock(): return self._read()

    def _save(self, value):
        raw = canonical(validate(value))
        self.backend.save(raw)
        if self.backend.load() != raw: raise StoreError('cloud_group/journal_readback')
        return raw

    def begin(self, owner, grant_hash, name, native_before, web_before):
        with self.lock():
            if self._read()[0] is not None: raise StoreError('cloud_group/scope_consumed')
            value = dict(schema=1, scope=ACCOUNT, attempt=secrets.token_hex(16), owner=owner, grant_hash=grant_hash,
                         name=name, native_before=native_before, web_before=web_before, phase='prepared', group_id=None)
            return self._save(value)

    def advance(self, token, phase, *, group_id_value=None):
        with self.lock():
            value, raw = self._read()
            if not value or raw != token or phase not in TRANSITIONS.get(value['phase'], set()):
                raise StoreError('cloud_group/journal_replaced')
            if phase == 'created': value['group_id'] = group_id_value
            elif group_id_value is not None: raise StoreError('cloud_group/journal_invalid')
            value['phase'] = phase
            return self._save(value)

    def close_unchanged(self, token, observations):
        """Seal an uncertain create after two matching, read-only baselines.

        This is not confirmation that the server will never apply the request.
        The original scope remains permanently consumed and cannot be resent.
        """
        with self.lock():
            value, raw = self._read()
            if not value or raw != token or value['phase'] != 'create_claimed':
                raise StoreError('cloud_group/journal_replaced')
            if not isinstance(observations, (list, tuple)) or len(observations) != 2:
                raise StoreError('cloud_group/observations')
            for pair in observations:
                if not isinstance(pair, (list, tuple)) or len(pair) != 2:
                    raise StoreError('cloud_group/observations')
                for index, key in enumerate(('native_before', 'web_before')):
                    source = pair[index]
                    if (not isinstance(source, dict) or not isinstance(source.get('groups'), dict)
                            or digest(source) != value[key]
                            or any(row.get('name') == value['name'] for row in source['groups'].values())):
                        raise StoreError('cloud_group/observations')
            value['phase'] = 'closed_unverified'
            return self._save(value)
