"""Fail-closed ordering for a future native UI one-shot, without transport.

The caller owns scoped read-only preflight and the actual native subprocess.
This helper never opens a network connection or declares cloud accounting done.
"""
from copy import deepcopy

from annotation_experiment_model import digest
from readtime_upload_model import integer
from native_time_bundle_selection import validate_selection


class Supervisor:
    def __init__(self,gate,store,bundle,grant,guest,config_token,current,preflight):
        self.gate,self.store=gate,store
        self.bundle,self.grant=deepcopy(bundle),deepcopy(grant)
        self.bundle_hash=digest(self.bundle)
        self.guest,self.config_token=guest,config_token
        self.grant_hash=digest(self.grant);self.signing_hash=digest([guest,config_token])
        self.current,self.preflight=current,preflight
        self.phase='initial';self.capture_receipt=None;self.dispatch_receipt=None;self.selection_hash=None;self.preflight_at=None

    def _fresh(self):
        bundle,receipt=self.store.read()
        return (self.current() is True and receipt==self.capture_receipt and bundle is not None
                and digest(bundle)==self.bundle_hash and digest(self.bundle)==self.bundle_hash
                and digest(self.grant)==self.grant_hash and digest([self.guest,self.config_token])==self.signing_hash)

    def _recent(self):
        now,_zone=self.gate._wall_clock()
        return self.preflight_at is not None and 0<=now-self.preflight_at<30

    def prepare(self):
        if self.phase!='initial' or self.gate.read()!=(None,None) or self.current() is not True:
            raise ValueError('bundle_supervisor/state')
        captured,self.capture_receipt=self.store.read()
        if captured is None or digest(captured)!=self.bundle_hash or self.capture_receipt is None:
            raise ValueError('bundle_supervisor/capture')
        observed=self.preflight()
        flags=('exact_capture_and_fixture_bound','fixture_in_captured_baseline',
               'both_positions_source_counts_and_original_shelf_exact','two_statistics_reads_stable','server_clock_after_boundary')
        now,_zone=self.gate._wall_clock()
        if (not isinstance(observed,dict) or observed.get('result')!='CROSS_DAY_READONLY_VERIFIED'
                or any(observed.get(k) is not True for k in flags) or type(observed.get('seconds')) is not int
                or observed['seconds']!=self.bundle['plan']['seconds']
                or not integer(observed.get('completed_at'),self.bundle['plan']['not_before'],4102444800)
                or not 0<=now-observed['completed_at']<30
                or any(type(observed.get(k)) is not int or observed[k]!=0 for k in ('account_data_posts','authentication_posts'))
                or observed.get('historical_accounting_verified') is not False or observed.get('dispatch_capability') is not False
                or not self._fresh() or self.gate.read()!=(None,None)):
            raise ValueError('bundle_supervisor/preflight')
        self.preflight_at=observed['completed_at'];self.phase='prepared'

    def select(self,selection):
        if self.phase!='prepared' or not self._fresh():raise ValueError('bundle_supervisor/state')
        if not self._recent():raise ValueError('bundle_supervisor/preflight_expired')
        validate_selection(self.bundle,selection)
        self.selection_hash=digest(selection)
        self.phase='selected'

    def claim(self,body,selection):
        if self.phase!='selected' or not self._fresh():raise ValueError('bundle_supervisor/state')
        if not self._recent():raise ValueError('bundle_supervisor/preflight_expired')
        validate_selection(self.bundle,selection)
        if digest(selection)!=self.selection_hash or not self._fresh():raise ValueError('bundle_supervisor/selection')
        # Reject malformed bodies before reserving; this has no side effects.
        self.gate.preview(self.bundle,self.grant,body,self.guest,self.config_token)
        if not self._fresh():raise ValueError('bundle_supervisor/stale_before_reserve')
        # The gate writes a permanent claim before a caller may deliver its
        # permission to the native request. An exception never implies no write.
        reserved=self.gate.reserve(self.bundle,self.grant)
        if not self._fresh():raise ValueError('bundle_supervisor/stale_before_claim')
        self.dispatch_receipt=self.gate.claim(reserved,self.bundle,self.grant,body,self.guest,self.config_token)
        self.phase='claimed'
        if not self._fresh():raise ValueError('bundle_supervisor/stale_after_claim')
        if not self._recent():raise ValueError('bundle_supervisor/preflight_expired')
        self.gate.assert_claim_current(self.dispatch_receipt,self.bundle,self.grant,body,self.guest,self.config_token)
        return self.dispatch_receipt

    def acknowledge(self,response):
        if self.phase!='claimed':raise ValueError('bundle_supervisor/state')
        # This records an explicit receipt only; it does not prove accounting.
        self.dispatch_receipt=self.gate.acknowledge(self.dispatch_receipt,response)
        self.phase='acknowledged'
        return self.dispatch_receipt
