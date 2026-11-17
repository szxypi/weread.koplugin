"""Immutable private baseline for later read-only accounting recovery.

The store records no source body or credentials, performs no account network
calls and cannot send, claim, or mark a request as verified. Its snapshots may
contain private position summaries and therefore live only in Keychain.
"""
from contextlib import nullcontext
from copy import deepcopy
import json
from pathlib import Path
import re
import tempfile
import time

from annotation_experiment_model import canonical,digest
from native_time_bundle_accounting import BASELINE_FIELDS,audit,baseline
from native_time_bundle_gate import binding,day
from readtime_upload_model import integer
from secure_highlight_trial import Receipt
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,MacKeychain,StoreError
from verify_native_position_lua import equivalent

SERVICE='org.codex.weread.goal-native-time-bundle-audit-v1'


class AuditStore:
    def __init__(self,backend=None,lock=None,*,clock=time.time):
        real=backend is None or isinstance(backend,MacKeychain) and backend.service==SERVICE
        if real and clock is not time.time:raise ValueError('bundle_audit/clock_override')
        self.backend=backend if backend is not None else MacKeychain(service=SERVICE,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/('codex-native-time-bundle-audit-'+ACCOUNT+'.lock')
        self.lock=lock or ((lambda:project_lock(path)) if backend is None else nullcontext)
        self.clock=clock

    def _now(self):
        if isinstance(self.backend,MacKeychain) and self.backend.service==SERVICE and self.clock is not time.time:
            raise ValueError('bundle_audit/clock_override')
        return int(self.clock())

    def _read(self):
        raw=self.backend.load()
        if raw is None:return None,None
        try:
            if not isinstance(raw,bytes) or not 0<len(raw)<=65536:raise ValueError()
            v=json.loads(raw)
            if (not isinstance(v,dict) or set(v)!={'schema','scope','phase','attempt','binding_sha256','baseline'}
                    or type(v['schema']) is not int or v['schema']!=1 or v['scope']!=ACCOUNT or v['phase']!='baseline'
                    or not isinstance(v['attempt'],str) or not re.fullmatch('[a-f0-9]{32}',v['attempt'])
                    or not isinstance(v['binding_sha256'],str) or not re.fullmatch('[a-f0-9]{64}',v['binding_sha256'])
                    or not isinstance(v['baseline'],dict) or set(v['baseline'])!=BASELINE_FIELDS):raise ValueError()
            return v,raw
        except Exception:raise StoreError('bundle_audit/record') from None

    def read(self):
        with self.lock():
            value,raw=self._read();return value,Receipt(raw) if raw is not None else None

    def seal(self,bundle,grant,gate,snapshot,months,prepared_at):
        original=baseline(bundle,grant,snapshot,months,prepared_at)
        now=self._now()
        if not 0<=now-prepared_at<30 or day(now)!=day(prepared_at):raise ValueError('bundle_audit/stale')
        state,receipt=gate.read()
        if (not state or state['phase']!='prepared' or receipt is None
                or state['binding']!=binding(bundle,grant,now)):
            raise ValueError('bundle_audit/gate')
        value={'schema':1,'scope':ACCOUNT,'phase':'baseline','attempt':state['attempt'],
               'binding_sha256':digest(state['binding']),'baseline':original}
        raw=canonical(value)
        if len(raw)>65536:raise StoreError('bundle_audit/size')
        with self.lock():
            if self._read()!=(None,None):raise StoreError('bundle_audit/consumed')
            if gate.read()!=(state,receipt):raise ValueError('bundle_audit/gate_changed')
            self.backend.save(raw)
            if self.backend.load()!=raw:raise StoreError('bundle_audit/readback')
            verified,token=self._read()
            if verified!=value or gate.read()!=(state,receipt):raise StoreError('bundle_audit/readback')
            return Receipt(token)

    def inspect(self,bundle,grant,gate):
        value,receipt=self.read();state,gate_receipt=gate.read()
        if (not value or not state or gate_receipt is None or state['phase'] not in ('prepared','claimed','acknowledged')
                or state['attempt']!=value['attempt'] or digest(state['binding'])!=value['binding_sha256']):
            raise ValueError('bundle_audit/gate')
        saved=value['baseline'];verified=baseline(bundle,grant,saved['snapshot'],saved['months'],saved['prepared_at'])
        if not equivalent(saved,verified):raise ValueError('bundle_audit/baseline')
        if state['phase']!='prepared' and (not integer(state['claimed_at'],saved['prepared_at'],4102444800)
                or state['claimed_at']-saved['prepared_at']>=30 or day(state['claimed_at'])!=day(saved['prepared_at'])):
            raise ValueError('bundle_audit/gate')
        return deepcopy(saved),receipt,state,gate_receipt

    def check_acknowledged(self,bundle,grant,gate,samples):
        saved,receipt,state,gate_receipt=self.inspect(bundle,grant,gate)
        if state['phase']!='acknowledged':raise ValueError('bundle_audit/no_ack')
        result=audit(bundle,grant,saved,samples,state['claimed_at'])
        if self.read()[1]!=receipt or gate.read()!=(state,gate_receipt):raise ValueError('bundle_audit/changed')
        return result
