"""Independent, permanent intent for a group containing one uploaded fixture."""
from contextlib import nullcontext
import json
from pathlib import Path
import re
import secrets
import tempfile

from cloud_group_contract import canonical, group_id, temporary_name
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT, MacKeychain, StoreError
from verify_cb_progress import cb_id

SERVICE = 'org.codex.weread.goal-cloud-group-nonempty-v1'
TRANSITIONS = {'prepared': 'create_claimed', 'create_claimed': 'created',
               'created': 'delete_claimed', 'delete_claimed': 'restored'}


def validate(value):
    keys = {'schema', 'scope', 'attempt', 'owner', 'grant_hash', 'name', 'target', 'upload_attempt',
            'upload_plan_hash', 'native_before', 'web_before', 'phase', 'group_id', 'dispatched'}
    if (not isinstance(value, dict) or set(value) != keys or type(value['schema']) is not int
            or value['schema'] != 1 or value['scope'] != ACCOUNT
            or not isinstance(value['owner'], str) or not re.fullmatch('[1-9][0-9]{0,19}', value['owner'])
            or not temporary_name(value['name']) or not cb_id(value['target'])
            or value['phase'] not in set(TRANSITIONS) | {'restored'} or type(value['dispatched']) is not bool):
        raise StoreError('cloud_group_nonempty/journal_invalid')
    for key in ('attempt', 'upload_attempt'):
        if not isinstance(value[key], str) or not re.fullmatch('[a-f0-9]{32}', value[key]):
            raise StoreError('cloud_group_nonempty/journal_invalid')
    for key in ('grant_hash', 'upload_plan_hash', 'native_before', 'web_before'):
        if not isinstance(value[key], str) or not re.fullmatch('[a-f0-9]{64}', value[key]):
            raise StoreError('cloud_group_nonempty/journal_invalid')
    if value['phase'] in ('prepared', 'create_claimed'):
        if value['group_id'] is not None: raise StoreError('cloud_group_nonempty/journal_invalid')
    elif not isinstance(value['group_id'], str) or not group_id(value['group_id']) or value['group_id'] == '1':
        raise StoreError('cloud_group_nonempty/journal_invalid')
    if value['dispatched'] and value['phase'] not in ('create_claimed', 'delete_claimed'):
        raise StoreError('cloud_group_nonempty/journal_invalid')
    return value


class Journal:
    def __init__(self, backend=None, lock=None):
        self.backend = backend if backend is not None else MacKeychain(service=SERVICE, account=ACCOUNT)
        path = Path(tempfile.gettempdir()) / ('codex-cloud-group-nonempty-' + ACCOUNT + '.lock')
        self.lock = lock or ((lambda: project_lock(path)) if backend is None else nullcontext)

    def _read(self):
        raw = self.backend.load()
        if raw is None: return None, None
        try:
            if not isinstance(raw, bytes) or not 0 < len(raw) <= 8192: raise ValueError()
            return validate(json.loads(raw)), raw
        except (ValueError, TypeError, UnicodeError, KeyError):
            raise StoreError('cloud_group_nonempty/journal_invalid') from None

    def read(self):
        with self.lock(): return self._read()

    def _save(self, value):
        raw = canonical(validate(value))
        self.backend.save(raw)
        if self.backend.load() != raw: raise StoreError('cloud_group_nonempty/readback')
        return raw

    def begin(self, *, owner, grant_hash, name, target, upload_attempt, upload_plan_hash, native_before, web_before):
        with self.lock():
            if self._read()[0] is not None: raise StoreError('cloud_group_nonempty/scope_consumed')
            return self._save(dict(schema=1, scope=ACCOUNT, attempt=secrets.token_hex(16), owner=owner,
                grant_hash=grant_hash, name=name, target=target, upload_attempt=upload_attempt,
                upload_plan_hash=upload_plan_hash, native_before=native_before, web_before=web_before,
                phase='prepared', group_id=None, dispatched=False))

    def claim_dispatch(self, token, phase):
        """Permanently consume this phase before transport, including on crash."""
        with self.lock():
            value, raw = self._read()
            if not value or raw != token or value['phase'] != phase or phase not in ('create_claimed', 'delete_claimed') or value['dispatched']:
                raise StoreError('cloud_group_nonempty/stale')
            value['dispatched'] = True
            return self._save(value)

    def advance(self, token, phase, *, group_id_value=None):
        with self.lock():
            value, raw = self._read()
            if not value or raw != token or TRANSITIONS.get(value['phase']) != phase:
                raise StoreError('cloud_group_nonempty/stale')
            if value['phase'] in ('create_claimed', 'delete_claimed') and not value['dispatched']:
                raise StoreError('cloud_group_nonempty/stale')
            if phase == 'created': value['group_id'] = group_id_value
            elif group_id_value is not None: raise StoreError('cloud_group_nonempty/journal_invalid')
            value['phase'] = phase; value['dispatched'] = False
            return self._save(value)
