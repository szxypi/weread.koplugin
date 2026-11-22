"""One non-replayable three-write ordinary XHTML trial; never sends requests.

Only a scoped baseline, target, counters and fingerprints are retained in a
separate Keychain item. An ambiguous send leaves its pending state intact.
"""
from contextlib import nullcontext
import json
from pathlib import Path
import re
import secrets
import tempfile

from readtime_upload_model import integer
from secure_native_session import project_lock
from secure_shelf_experiment import Receipt, canonical
from secure_weread_session import ACCOUNT, MacKeychain, StoreError

SERVICE = 'org.codex.weread.goal-ordinary-reconnect-v1'
PROTOCOL = 'ordinary-xhtml-offline-reconnect-zero-time-v1'
HASHES = {'owner_sha256', 'grant_sha256', 'web_session_sha256', 'source_sha256', 'catalog_sha256',
          'web_shelf_sha256', 'native_shelf_sha256'}
POINT = {'book_id', 'chapter_uid', 'chapter_idx', 'chapter_offset', 'raw_percent', 'summary'}
COUNTS = {'readingTime', 'recordReadingTime', 'ttsTime'}
PHASES = {'prepared': 0, 'enter_pending': 1, 'enter_acknowledged': 1, 'enter_verified': 1,
          'position_pending': 2, 'position_acknowledged': 2, 'position_verified': 2,
          'restore_pending': 3, 'restore_acknowledged': 3, 'retired': 3}
ORDER = tuple(PHASES)
TRANSITIONS = set(zip(ORDER, ORDER[1:]))


def validate_point(point):
    if not isinstance(point, dict) or set(point) != POINT:
        raise StoreError('ordinary_trial/point')
    if any(not isinstance(point[k], str) or not re.fullmatch(r'[1-9][0-9]{0,19}', point[k])
           for k in ('book_id', 'chapter_uid')):
        raise StoreError('ordinary_trial/point')
    try:
        encoded_summary = point['summary'].encode('utf-8') if isinstance(point['summary'], str) else b''
    except UnicodeEncodeError:
        raise StoreError('ordinary_trial/point') from None
    if (not integer(point['chapter_idx'], 0, 1000000)
            or not integer(point['chapter_offset'], 0, 2147483647)
            or not integer(point['raw_percent'], 0, 100)
            or not isinstance(point['summary'], str) or len(point['summary']) > 20
            or len(encoded_summary) > 80
            or any(ord(c) < 32 and c not in '\t\r\n' for c in point['summary'])):
        raise StoreError('ordinary_trial/point')


def validate_plan(plan):
    if (not isinstance(plan, dict) or set(plan) != HASHES | {'protocol', 'baseline', 'target', 'counts', 'version'}
            or plan['protocol'] != PROTOCOL):
        raise StoreError('ordinary_trial/plan')
    if any(not isinstance(plan[k], str) or not re.fullmatch(r'[a-f0-9]{64}', plan[k]) for k in HASHES):
        raise StoreError('ordinary_trial/plan')
    validate_point(plan['baseline']); validate_point(plan['target'])
    first, target = plan['baseline'], plan['target']
    if (any(first[k] != target[k] for k in ('book_id', 'chapter_uid', 'chapter_idx'))
            or first['chapter_offset'] == target['chapter_offset']
            or not isinstance(plan['counts'], dict) or set(plan['counts']) != COUNTS
            or any(not integer(value, 0, 2**53-1) for value in plan['counts'].values())
            or not integer(plan['version'], 0, 2147483647)):
        raise StoreError('ordinary_trial/plan')
    return plan


class OrdinaryReconnectStore:
    def __init__(self, backend=None, lock=None):
        self.backend = backend if backend is not None else MacKeychain(service=SERVICE, account=ACCOUNT)
        path = Path(tempfile.gettempdir()) / ('codex-ordinary-reconnect-' + ACCOUNT + '.lock')
        self.lock = lock or ((lambda: project_lock(path)) if backend is None else nullcontext)

    def _load(self):
        raw = self.backend.load()
        if raw is None:
            return None, None
        try:
            if not isinstance(raw, bytes) or not 0 < len(raw) <= 16384:
                raise ValueError()
            value = json.loads(raw)
            if (not isinstance(value, dict) or set(value) != {'schema', 'scope', 'attempt', 'phase', 'posts', 'plan'}
                    or type(value['schema']) is not int or value['schema'] != 1 or value['scope'] != ACCOUNT
                    or not isinstance(value['attempt'], str) or not re.fullmatch(r'[a-f0-9]{32}', value['attempt'])
                    or value['phase'] not in PHASES or type(value['posts']) is not int
                    or value['posts'] != PHASES[value['phase']]):
                raise ValueError()
            validate_plan(value['plan'])
            return value, raw
        except Exception:
            raise StoreError('ordinary_trial/intent_invalid') from None

    def read(self):
        with self.lock():
            value, raw = self._load()
            return value, Receipt(raw) if raw else None

    def pending(self):
        state, _ = self.read()
        return state is not None and state['phase'] != 'retired'

    def _write(self, value):
        raw = canonical(value)
        if len(raw) > 16384:
            raise StoreError('ordinary_trial/intent_invalid')
        self.backend.save(raw)
        if self.backend.load() != raw:
            raise StoreError('ordinary_trial/readback')
        self._load()
        return Receipt(raw)

    def reserve(self, plan):
        validate_plan(plan)
        with self.lock():
            if self._load()[0] is not None:
                raise StoreError('ordinary_trial/consumed')
            return self._write(dict(schema=1, scope=ACCOUNT, attempt=secrets.token_hex(16),
                                    phase='prepared', posts=0, plan=plan))

    def advance(self, receipt, before, after):
        if (before, after) not in TRANSITIONS:
            raise StoreError('ordinary_trial/phase')
        with self.lock():
            state, raw = self._load()
            if not isinstance(receipt, Receipt) or raw != receipt.pending or state is None or state['phase'] != before:
                raise StoreError('ordinary_trial/replaced')
            state['phase'], state['posts'] = after, PHASES[after]
            return self._write(state)
