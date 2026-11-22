"""One non-replayable three-write ordinary XHTML trial; never sends requests.

Only a scoped baseline, target, counters and fingerprints are retained in a
separate Keychain item. An ambiguous send leaves its pending state intact.
"""
from contextlib import nullcontext
import hashlib
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
CORE_HASHES = {'web_shelf_core_sha256', 'native_shelf_core_sha256'}
POINT = {'book_id', 'chapter_uid', 'chapter_idx', 'chapter_offset', 'raw_percent', 'summary'}
COUNTS = {'readingTime', 'recordReadingTime', 'ttsTime'}
PHASES = {'prepared': 0, 'enter_pending': 1, 'enter_acknowledged': 1, 'enter_verified': 1,
          'position_pending': 2, 'position_acknowledged': 2, 'position_verified': 2,
          'restore_pending': 3, 'restore_acknowledged': 3, 'retired': 3}
ORDER = tuple(PHASES)
TRANSITIONS = set(zip(ORDER, ORDER[1:]))
PHASES['partial_restored'] = 1
PHASES['partial_restored_after_position'] = 2
PHASES['restore_readback_confirmed'] = 3
PHASES['baseline_readback_after_enter'] = 1
PHASES['baseline_readback_after_position'] = 2


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
    fields=HASHES | {'protocol', 'baseline', 'target', 'counts', 'version'}
    if (not isinstance(plan, dict) or set(plan) not in (fields, fields | CORE_HASHES)
            or plan['protocol'] != PROTOCOL):
        raise StoreError('ordinary_trial/plan')
    if any(not isinstance(plan[k], str) or not re.fullmatch(r'[a-f0-9]{64}', plan[k]) for k in HASHES):
        raise StoreError('ordinary_trial/plan')
    if CORE_HASHES <= set(plan) and any(not isinstance(plan[k],str) or not re.fullmatch(r'[a-f0-9]{64}',plan[k]) for k in CORE_HASHES):
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


def entered_point(plan):
    """The observed enter updates source location while keeping the old percent."""
    validate_plan(plan)
    first,target=plan['baseline'],plan['target']
    return dict(first,chapter_offset=target['chapter_offset'],summary=target['summary'])


class OrdinaryReconnectStore:
    service = SERVICE
    lock_name = 'codex-ordinary-reconnect-'
    def validate_plan(self, plan):
        validate_plan(plan)
        if CORE_HASHES & set(plan):raise StoreError('ordinary_trial/plan')
    def __init__(self, backend=None, lock=None):
        self.backend = backend if backend is not None else MacKeychain(service=self.service, account=ACCOUNT)
        path = Path(tempfile.gettempdir()) / (self.lock_name + ACCOUNT + '.lock')
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
            self.validate_plan(value['plan'])
            return value, raw
        except Exception:
            raise StoreError('ordinary_trial/intent_invalid') from None

    def read(self):
        with self.lock():
            value, raw = self._load()
            return value, Receipt(raw) if raw else None

    def pending(self):
        state, _ = self.read()
        return state is not None and state['phase'] not in ('retired', 'partial_restored', 'partial_restored_after_position',
                                                            'restore_readback_confirmed','baseline_readback_after_enter','baseline_readback_after_position')

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
        self.validate_plan(plan)
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

    def retire_after_partial_recovery(self, receipt, recovery):
        """Seal the partial attempt only after its distinct recovery is retired."""
        from secure_ordinary_partial_recovery import PartialRecoveryStore,RetryPartialRecoveryStore,ThirdPartialRecoveryStore,FourthPartialRecoveryStore
        if not isinstance(receipt,Receipt) or not isinstance(recovery,PartialRecoveryStore):
            raise StoreError('ordinary_trial/recovery')
        with self.lock():
            state,raw=self._load();completed,_=recovery.read()
            if type(self) in (OrdinaryReconnectRetryStore,OrdinaryReconnectThirdStore,OrdinaryReconnectFourthStore):
                expected={OrdinaryReconnectRetryStore:RetryPartialRecoveryStore,OrdinaryReconnectThirdStore:ThirdPartialRecoveryStore,
                          OrdinaryReconnectFourthStore:FourthPartialRecoveryStore}[type(self)]
                phase_ok=(type(recovery) is expected and state and completed and completed['binding'].get('original_phase')==state['phase'] and
                    (state['phase'] in ('enter_pending','enter_acknowledged','enter_verified') and completed and completed['binding'].get('observed_state')=='entered'
                     or state['phase'] in ('position_pending','position_acknowledged') and completed and completed['binding'].get('observed_state') in ('entered','target')))
            else:phase_ok=type(self) is OrdinaryReconnectStore and type(recovery) is PartialRecoveryStore and state and state['phase']=='enter_acknowledged'
            if (not state or raw!=receipt.pending or not phase_ok
                    or not completed or completed['phase']!='retired' or completed['posts']!=1
                    or completed['binding']['original_intent_sha256']!=hashlib.sha256(raw).hexdigest()):
                raise StoreError('ordinary_trial/recovery')
            state['phase']='partial_restored_after_position' if state['posts']==2 else 'partial_restored'
            return self._write(state)


class OrdinaryReconnectRetryStore(OrdinaryReconnectStore):
    """A distinct one-shot scope; it cannot reset or consume the old record."""
    service = 'org.codex.weread.goal-ordinary-reconnect-v2'
    lock_name = 'codex-ordinary-reconnect-v2-'
    def validate_plan(self,plan):
        validate_plan(plan)
        if not CORE_HASHES <= set(plan):raise StoreError('ordinary_trial/plan')

    def close_after_restore_readback(self,receipt,proof,bridge):
        """Seal an uncertain attempt only after a separate verified baseline readback."""
        from secure_ordinary_restore_readback import RestoreReadbackStore,ThirdRestoreReadbackStore,FourthRestoreReadbackStore
        from secure_ordinary_recovery_renewal import RetryRecoveryRenewalStore,ThirdRecoveryRenewalStore,FourthRecoveryRenewalStore
        scopes={OrdinaryReconnectRetryStore:(RestoreReadbackStore,RetryRecoveryRenewalStore),
                OrdinaryReconnectThirdStore:(ThirdRestoreReadbackStore,ThirdRecoveryRenewalStore),
                OrdinaryReconnectFourthStore:(FourthRestoreReadbackStore,FourthRecoveryRenewalStore)}
        if type(self) not in scopes:raise StoreError('ordinary_trial/readback')
        expected_proof,expected_bridge=scopes[type(self)]
        if not isinstance(receipt,Receipt) or type(proof) is not expected_proof or type(bridge) is not expected_bridge:
            raise StoreError('ordinary_trial/readback')
        with self.lock():
            state,raw=self._load();verified,_=proof.read();renewed,renewal_receipt=bridge.read()
            allowed=('enter_pending','enter_acknowledged','enter_verified','position_pending','position_acknowledged','position_verified',
                     'restore_pending','restore_acknowledged')
            if not state or raw!=receipt.pending or state['phase'] not in allowed or not verified:
                raise StoreError('ordinary_trial/readback')
            plan=state['plan'];bound=verified['binding'];original_hash=hashlib.sha256(raw).hexdigest()
            if (bound['original_intent_sha256']!=original_hash or bound['owner_sha256']!=plan['owner_sha256']
                    or bound['source_sha256']!=plan['source_sha256'] or bound['catalog_sha256']!=plan['catalog_sha256']
                    or bound['web_shelf_core_sha256']!=plan['web_shelf_core_sha256']
                    or bound['native_shelf_core_sha256']!=plan['native_shelf_core_sha256']):
                raise StoreError('ordinary_trial/readback')
            if renewed is None:
                if (renewal_receipt is not None or bound['native_grant_sha256']!=plan['grant_sha256']
                        or bound['renewal_bridge_sha256']!='0'*64):raise StoreError('ordinary_trial/readback')
            elif (not renewal_receipt or renewed['phase']!='verified' or renewed['new_grant_sha256']!=bound['native_grant_sha256']
                    or renewed['binding']['original_intent_sha256']!=original_hash
                    or renewed['binding']['owner_sha256']!=plan['owner_sha256']
                    or renewed['binding']['old_grant_sha256']!=plan['grant_sha256']
                    or hashlib.sha256(renewal_receipt.pending).hexdigest()!=bound['renewal_bridge_sha256']):
                raise StoreError('ordinary_trial/readback')
            state['phase']={1:'baseline_readback_after_enter',2:'baseline_readback_after_position',3:'restore_readback_confirmed'}[state['posts']]
            return self._write(state)


class OrdinaryReconnectThirdStore(OrdinaryReconnectRetryStore):
    """Independent scope; previous trial and recovery records remain immutable."""
    service='org.codex.weread.goal-ordinary-reconnect-v3'
    lock_name='codex-ordinary-reconnect-v3-'


class OrdinaryReconnectFourthStore(OrdinaryReconnectRetryStore):
    service='org.codex.weread.goal-ordinary-reconnect-v4'
    lock_name='codex-ordinary-reconnect-v4-'
