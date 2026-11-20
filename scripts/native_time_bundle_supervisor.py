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

    def _valid_observed(self,observed,now):
        flags=('exact_capture_and_fixture_bound','fixture_in_captured_baseline',
               'both_positions_source_counts_and_original_shelf_exact','two_statistics_reads_stable','server_clock_after_boundary')
        return (isinstance(observed,dict) and observed.get('result')=='CROSS_DAY_READONLY_VERIFIED'
                and all(observed.get(k) is True for k in flags) and type(observed.get('seconds')) is int
                and observed['seconds']==self.bundle['plan']['seconds']
                and integer(observed.get('completed_at'),self.bundle['plan']['not_before'],4102444800)
                and 0<=now-observed['completed_at']<30
                and all(type(observed.get(k)) is int and observed[k]==0 for k in ('account_data_posts','authentication_posts'))
                and observed.get('historical_accounting_verified') is False and observed.get('dispatch_capability') is False)

    def prepare(self):
        if self.phase!='initial' or self.gate.read()!=(None,None) or self.current() is not True:
            raise ValueError('bundle_supervisor/state')
        captured,self.capture_receipt=self.store.read()
        if captured is None or digest(captured)!=self.bundle_hash or self.capture_receipt is None:
            raise ValueError('bundle_supervisor/capture')
        observed=self.preflight()
        now,_zone=self.gate._wall_clock()
        if not self._valid_observed(observed,now) or not self._fresh() or self.gate.read()!=(None,None):
            raise ValueError('bundle_supervisor/preflight')
        self.preflight_at=observed['completed_at'];self.phase='prepared'

    def select(self,selection):
        if self.phase!='prepared' or not self._fresh():raise ValueError('bundle_supervisor/state')
        if not self._recent():raise ValueError('bundle_supervisor/preflight_expired')
        validate_selection(self.bundle,selection)
        self.selection_hash=digest(selection)
        self.phase='selected'

    def _before_claim(self,reserved):
        pass

    def _before_release(self):
        pass

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
        self._before_claim(reserved)
        if not self._fresh() or not self._recent():raise ValueError('bundle_supervisor/stale_before_claim')
        self.dispatch_receipt=self.gate.claim(reserved,self.bundle,self.grant,body,self.guest,self.config_token)
        self.phase='claimed'
        self._before_release()
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


class AuditedSupervisor(Supervisor):
    """Seal a private baseline before releasing a claim; no network transport.

    Baseline provenance remains the responsibility of a future scoped preflight.
    This class is not connected to the real-account sender.
    """
    def __init__(self,*args,audit_store,snapshot,months,**kwargs):
        super().__init__(*args,**kwargs)
        self.audit_store=audit_store
        self.snapshot,self.months=deepcopy(snapshot),deepcopy(months)
        self.audit_receipt=None

    def _check_audit(self,phase,gate_receipt):
        saved,receipt,state,current=self.audit_store.inspect(self.bundle,self.grant,self.gate)
        if (receipt!=self.audit_receipt or state['phase']!=phase or current!=gate_receipt
                or saved['prepared_at']!=self.preflight_at or saved['snapshot']!=self.snapshot
                or saved['months']!=self.months):
            raise ValueError('bundle_supervisor/audit_changed')

    def _before_claim(self,reserved):
        self.audit_receipt=self.audit_store.seal(self.bundle,self.grant,self.gate,self.snapshot,self.months,self.preflight_at)
        self._check_audit('prepared',reserved)

    def _before_release(self):
        self._check_audit('claimed',self.dispatch_receipt)


class EvidenceSupervisor(AuditedSupervisor):
    """Use one private preflight result through sealing and claim release.

    This remains an offline coordinator: transport and authenticated readback
    must be provided separately, and no result here proves accounting.
    """
    def __init__(self,gate,store,bundle,grant,guest,config_token,current,*,audit_store,evidence):
        from native_time_bundle_evidence import PreflightEvidence
        if not isinstance(evidence,PreflightEvidence):raise ValueError('bundle_supervisor/evidence')
        self.evidence=evidence
        _report,snapshot,months=evidence.for_bundle(bundle,grant)
        super().__init__(gate,store,bundle,grant,guest,config_token,current,
                         lambda:self.evidence.for_bundle(self.bundle,self.grant)[0],
                         audit_store=audit_store,snapshot=snapshot,months=months)

    def _check_evidence(self):
        report,snapshot,months=self.evidence.for_bundle(self.bundle,self.grant)
        if (report['completed_at']!=self.preflight_at or digest(snapshot)!=digest(self.snapshot)
                or digest(months)!=digest(self.months)):
            raise ValueError('bundle_supervisor/evidence_changed')

    def _before_claim(self,reserved):
        self._check_evidence()
        super()._before_claim(reserved)
        self._check_evidence()

    def _before_release(self):
        super()._before_release()
        self._check_evidence()


class NativeBoundSupervisor(EvidenceSupervisor):
    """Check the native worker's persisted baseline before releasing a claim."""
    def _check_native(self):
        from native_time_bundle_native_record import validate_record
        body,selection,record,source_path,archive=self._native_input
        now,_zone=self.gate._wall_clock()
        validate_record(self.bundle,self.grant,self.evidence,selection,body,record,source_path,now,archive=archive)

    def claim(self,body,selection,record,source_path,*,archive=None):
        if getattr(self,'_native_input',None) is not None:raise ValueError('bundle_supervisor/native_state')
        self._native_input=deepcopy((body,selection,record,str(source_path),archive))
        try:
            self._check_native()
            return super().claim(self._native_input[0],self._native_input[1])
        finally:self._native_input=None

    def preview(self,body,selection,record,source_path,*,archive=None):
        """Validate a native request without reserving or releasing permission."""
        if self.phase!='selected' or getattr(self,'_native_input',None) is not None:
            raise ValueError('bundle_supervisor/state')
        self._native_input=deepcopy((body,selection,record,str(source_path),archive))
        try:
            body,selection,_record,_path,_archive=self._native_input
            if not self._fresh() or not self._recent() or self.gate.read()!=(None,None):
                raise ValueError('bundle_supervisor/stale')
            validate_selection(self.bundle,selection)
            if digest(selection)!=self.selection_hash:raise ValueError('bundle_supervisor/selection')
            self._check_evidence();self._check_native()
            self.gate.preview(self.bundle,self.grant,body,self.guest,self.config_token)
            if not self._fresh() or not self._recent() or self.gate.read()!=(None,None):
                raise ValueError('bundle_supervisor/stale')
            self._check_evidence();self._check_native()
            return True
        finally:self._native_input=None

    def _before_claim(self,reserved):
        self._check_native()
        super()._before_claim(reserved)
        self._check_native()

    def _before_release(self):
        super()._before_release()
        self._check_native()
