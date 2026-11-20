"""One-shot journal scoped exclusively to the independent time capture.

This module has no transport, token acquisition or send capability. A claimed
record is never reset or replayed, even after an interrupted process.
"""
from contextlib import nullcontext
from pathlib import Path
import secrets
import tempfile
import time

from native_time_bundle_gate import DispatchGate, binding, verify_request
from native_time_capture_fresh_bundle import store as independent_capture
from readtime_upload_model import local_zone
from secure_highlight_trial import Receipt
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT, MacKeychain, StoreError

SERVICE='org.codex.weread.goal-native-time-independent-dispatch-v1'


class IndependentGate(DispatchGate):
    """A separate durable scope which can only bind the newer capture."""
    def __init__(self,backend=None,lock=None,*,capture=None,clock=time.time,zone=local_zone):
        real=backend is None or isinstance(backend,MacKeychain)
        if real and (lock is not None or capture is not None or clock is not time.time or zone is not local_zone):
            raise ValueError('independent_gate/override')
        if real and backend is not None and (backend.service!=SERVICE or backend.account!=ACCOUNT):
            raise ValueError('independent_gate/scope')
        owned_backend=backend if backend is not None else MacKeychain(service=SERVICE,account=ACCOUNT)
        path=Path(tempfile.gettempdir())/('codex-native-time-independent-dispatch-'+ACCOUNT+'.lock')
        owned_lock=(lambda:project_lock(path)) if real else lock or nullcontext
        super().__init__(owned_backend,owned_lock,clock=clock,zone=zone)
        self.capture=independent_capture() if real else capture
        if self.capture is None or not callable(getattr(self.capture,'read',None)):
            raise ValueError('independent_gate/capture')
        self._real=real
        self._owned_backend=owned_backend
        self._owned_capture=self.capture
        self._owned_lock=owned_lock

    def _wall_clock(self):
        if self._real and (self.clock is not time.time or self.zone is not local_zone
                or self.backend is not self._owned_backend or self.capture is not self._owned_capture
                or self.lock is not self._owned_lock or self.backend.service!=SERVICE or self.backend.account!=ACCOUNT):
            raise ValueError('independent_gate/override')
        return int(self.clock()),self.zone()

    def _capture_matches(self,bundle):
        current,receipt=self.capture.read()
        if receipt is None or current!=bundle:raise StoreError('independent_gate/capture_changed')

    def preview(self,bundle,grant,body,guest,config_token):
        with self.lock():
            self._wall_clock();self._capture_matches(bundle)
            now,zone=self._wall_clock()
            return verify_request(bundle,grant,body,guest,config_token,now,zone)

    def reserve(self,bundle,grant):
        with self.lock():
            now,zone=self._wall_clock();self._capture_matches(bundle);bound=binding(bundle,grant,now)
            if zone!='+08:00':raise ValueError('bundle_gate/zone')
            if self._read()!=(None,None):raise StoreError('bundle_gate/consumed')
            self._capture_matches(bundle);later,later_zone=self._wall_clock()
            if later_zone!='+08:00' or binding(bundle,grant,later)!=bound:raise ValueError('bundle_gate/zone')
            return self._write(dict(schema=1,scope=ACCOUNT,attempt=secrets.token_hex(16),phase='prepared',binding=bound,
                                    request_sha256=None,claimed_at=None,ack_sha256=None))

    def claim(self,receipt,bundle,grant,body,guest,config_token):
        with self.lock():
            value,raw=self._read();now,zone=self._wall_clock();self._capture_matches(bundle)
            if (not isinstance(receipt,Receipt) or raw!=receipt.raw or value is None or value['phase']!='prepared'
                    or value['binding']!=binding(bundle,grant,now)):raise StoreError('bundle_gate/changed')
            request_hash=verify_request(bundle,grant,body,guest,config_token,now,zone)
            now,zone=self._wall_clock();self._capture_matches(bundle)
            if verify_request(bundle,grant,body,guest,config_token,now,zone)!=request_hash:
                raise ValueError('bundle_gate/request')
            value.update(phase='claimed',request_sha256=request_hash,claimed_at=now)
            return self._write(value)

    def assert_claim_current(self,receipt,bundle,grant,body,guest,config_token):
        with self.lock():
            value,raw=self._read();now,zone=self._wall_clock();self._capture_matches(bundle)
            if (not isinstance(receipt,Receipt) or raw!=receipt.raw or value is None or value['phase']!='claimed'
                    or value['binding']!=binding(bundle,grant,now)):
                raise StoreError('bundle_gate/changed')
            if verify_request(bundle,grant,body,guest,config_token,now,zone)!=value['request_sha256']:
                raise ValueError('bundle_gate/request')
            return True
