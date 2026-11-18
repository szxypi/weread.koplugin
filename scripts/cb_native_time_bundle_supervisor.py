"""Bind a CB native claim to captured evidence, a sealed baseline and one gate.

This coordinator does not perform network I/O or certify cloud accounting.
The caller must supply an authenticated read-only preflight and private channel.
"""
from copy import deepcopy

from annotation_experiment_model import digest
from cb_native_time_bundle_audit_store import AuditStore
from cb_native_time_bundle_evidence import PreflightEvidence
from cb_native_time_bundle_gate import DispatchGate
from cb_native_time_bundle_native_record import validate_record
from native_time_bundle_selection import validate_selection


class Supervisor:
    def __init__(self,gate,store,bundle,grant,guest,config,current,*,audit_store,evidence):
        if not isinstance(gate,DispatchGate) or not isinstance(audit_store,AuditStore) or not isinstance(evidence,PreflightEvidence) or not callable(current):
            raise ValueError('cb_supervisor/input')
        self.gate,self.store,self.audit_store,self.evidence=gate,store,audit_store,evidence
        self.bundle,self.grant=deepcopy(bundle),deepcopy(grant)
        self.bundle_hash,self.grant_hash=digest(bundle),digest(grant)
        self.guest,self.config,self.signing_hash=guest,config,digest([guest,config])
        self.current=current;self.phase='initial';self.capture_receipt=self.dispatch_receipt=self.audit_receipt=None
        self.selection_hash=self.preflight_at=None
    def _fresh(self):
        bundle,receipt=self.store.read()
        return (self.current() is True and receipt==self.capture_receipt and bundle is not None
                and digest(bundle)==self.bundle_hash and digest(self.bundle)==self.bundle_hash
                and digest(self.grant)==self.grant_hash and digest([self.guest,self.config])==self.signing_hash)
    def _recent(self):
        now,_zone=self.gate._wall_clock()
        return self.preflight_at is not None and 0<=now-self.preflight_at<30
    def _check_evidence(self):
        report,snapshot,months=self.evidence.for_bundle(self.bundle,self.grant)
        if report['completed_at']!=self.preflight_at or digest(snapshot)!=self.snapshot_hash or digest(months)!=self.months_hash:
            raise ValueError('cb_supervisor/evidence')
        return snapshot,months
    def _check_native(self,body,selection,record,source_path):
        now,_zone=self.gate._wall_clock()
        validate_record(self.bundle,self.grant,self.evidence,selection,body,record,source_path,now)
    def _check_audit(self,phase,receipt):
        saved,token,state,current=self.audit_store.inspect(self.bundle,self.grant,self.gate)
        if (token!=self.audit_receipt or state['phase']!=phase or current!=receipt or saved['prepared_at']!=self.preflight_at
                or digest(saved['snapshot'])!=self.snapshot_hash or digest(saved['months'])!=self.months_hash):
            raise ValueError('cb_supervisor/audit')
    def prepare(self):
        try:
            if self.phase!='initial' or self.current() is not True or self.gate.read()!=(None,None) or self.audit_store.read()!=(None,None):
                raise ValueError('cb_supervisor/state')
            captured,self.capture_receipt=self.store.read()
            if captured is None or self.capture_receipt is None or digest(captured)!=self.bundle_hash:raise ValueError('cb_supervisor/capture')
            report,snapshot,months=self.evidence.for_bundle(self.bundle,self.grant)
            self.preflight_at=report['completed_at'];self.snapshot_hash=digest(snapshot);self.months_hash=digest(months)
            if not self._recent() or not self._fresh() or self.gate.read()!=(None,None) or self.audit_store.read()!=(None,None):
                raise ValueError('cb_supervisor/stale')
            self.phase='prepared'
        except BaseException:
            self.phase='stopped';raise
    def select(self,selection):
        try:
            if self.phase!='prepared' or not self._fresh() or not self._recent():raise ValueError('cb_supervisor/state')
            validate_selection(self.bundle,selection,imported=True);self.selection_hash=digest(selection);self.phase='selected'
        except BaseException:
            self.phase='stopped';raise
    def _preclaim(self,body,selection,record,source_path):
        if self.phase!='selected' or not self._fresh() or not self._recent() or self.gate.read()!=(None,None) or self.audit_store.read()!=(None,None):
            raise ValueError('cb_supervisor/state')
        validate_selection(self.bundle,selection,imported=True)
        if digest(selection)!=self.selection_hash:raise ValueError('cb_supervisor/selection')
        snapshot,months=self._check_evidence();self._check_native(body,selection,record,source_path)
        self.gate.preview(self.bundle,self.grant,snapshot,body,self.guest,self.config)
        if not self._fresh() or not self._recent():raise ValueError('cb_supervisor/stale')
        return snapshot,months
    def preview(self,body,selection,record,source_path):
        try:
            self._preclaim(body,selection,record,source_path)
            if self.gate.read()!=(None,None) or self.audit_store.read()!=(None,None):raise ValueError('cb_supervisor/stale')
            self._check_evidence();self._check_native(body,selection,record,source_path)
            return True
        except BaseException:
            self.phase='stopped';raise
    def claim(self,body,selection,record,source_path):
        try:
            frozen=deepcopy((body,selection,record,str(source_path)));body,selection,record,source_path=frozen
            snapshot,months=self._preclaim(body,selection,record,source_path)
            reserved=self.gate.reserve(self.bundle,self.grant,snapshot)
            if not self._fresh() or not self._recent():raise ValueError('cb_supervisor/stale')
            self._check_native(body,selection,record,source_path);self._check_evidence()
            self.audit_receipt=self.audit_store.seal(self.bundle,self.grant,self.gate,snapshot,months,self.preflight_at)
            self._check_audit('prepared',reserved);self._check_native(body,selection,record,source_path)
            if not self._fresh() or not self._recent():raise ValueError('cb_supervisor/stale')
            self.dispatch_receipt=self.gate.claim(reserved,self.bundle,self.grant,snapshot,body,self.guest,self.config)
            self.phase='claimed';self._check_audit('claimed',self.dispatch_receipt)
            self._check_native(body,selection,record,source_path);self._check_evidence()
            if not self._fresh() or not self._recent():raise ValueError('cb_supervisor/stale')
            self.gate.assert_claim_current(self.dispatch_receipt,self.bundle,self.grant,snapshot,body,self.guest,self.config)
            return self.dispatch_receipt
        except BaseException:
            self.phase='stopped';raise
    def acknowledge(self,response):
        try:
            if self.phase!='claimed':raise ValueError('cb_supervisor/state')
            self.dispatch_receipt=self.gate.acknowledge(self.dispatch_receipt,response);self.phase='acknowledged'
            return self.dispatch_receipt
        except BaseException:
            self.phase='stopped';raise
