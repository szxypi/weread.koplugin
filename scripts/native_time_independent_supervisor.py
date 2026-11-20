"""Bind the new capture's native worker to its own durable journals.

This coordinator performs no account transport. Its caller must authenticate
the private preflight and worker; a claim never by itself proves accounting.
"""
from copy import deepcopy

from annotation_experiment_model import digest
from native_time_bundle_accounting import baseline
from native_time_bundle_evidence import IndependentCaptureEvidence
from native_time_bundle_native_record import validate_record
from native_time_bundle_supervisor import NativeBoundSupervisor,Supervisor
from native_time_independent_audit import IndependentAudit,MAX_RECORD_BYTES,packet_size
from native_time_independent_gate import IndependentGate


class _NativeEvidence:
    def __init__(self,evidence):self.evidence=evidence
    def for_bundle(self,bundle,grant):return self.evidence.for_bundle(bundle,grant)[:3]
    def catalog_stamp(self,bundle,grant):return self.evidence.for_bundle(bundle,grant)[3]


class IndependentNativeBoundSupervisor(NativeBoundSupervisor):
    def __init__(self,gate,store,bundle,grant,guest,config_token,current,*,audit_store,evidence):
        if (not isinstance(gate,IndependentGate) or not isinstance(audit_store,IndependentAudit)
                or not isinstance(evidence,IndependentCaptureEvidence) or not callable(current)):
            raise ValueError('independent_supervisor/evidence')
        if gate._real!=audit_store._real:raise ValueError('independent_supervisor/scope')
        report,snapshot,months,stamp,shelves,components=evidence.for_bundle(bundle,grant)
        self.evidence,self.audit_store=evidence,audit_store
        self._packet={'report':report,'baseline':baseline(bundle,grant,snapshot,months,report['completed_at']),
                      'catalog_stamp':stamp,'shelves':list(shelves)}
        self._include_components=components is not None
        if self._include_components:
            self._packet['components']=list(components);self._packet['components_sha256']=digest(components)
            if packet_size(self._packet)>MAX_RECORD_BYTES:
                self._packet.pop('components');self._packet.pop('components_sha256');self._include_components=False
        if packet_size(self._packet)>MAX_RECORD_BYTES:raise ValueError('independent_supervisor/audit_size')
        self.audit_receipt=None
        Supervisor.__init__(self,gate,store,bundle,grant,guest,config_token,current,
                            lambda:self.evidence.for_bundle(self.bundle,self.grant)[0])

    def prepare(self):
        if self.audit_store.read()!=(None,None):raise ValueError('independent_supervisor/audit_consumed')
        self.gate._capture_matches(self.bundle)
        super().prepare()
        if self.audit_store.read()!=(None,None):raise ValueError('independent_supervisor/audit_consumed')

    def _valid_observed(self,observed,now):
        report=self.evidence.for_bundle(self.bundle,self.grant)[0]
        return observed==report and 0<=now-report['completed_at']<30

    def _check_evidence(self):
        report,snapshot,months,stamp,shelves,components=self.evidence.for_bundle(self.bundle,self.grant)
        packet={'report':report,'baseline':baseline(self.bundle,self.grant,snapshot,months,report['completed_at']),
                'catalog_stamp':stamp,'shelves':list(shelves)}
        if self._include_components:
            if components is None:raise ValueError('independent_supervisor/evidence_changed')
            packet['components']=list(components);packet['components_sha256']=digest(components)
        if packet!=self._packet or report['completed_at']!=self.preflight_at:
            raise ValueError('independent_supervisor/evidence_changed')
        self.gate._capture_matches(self.bundle)

    def _check_native(self):
        body,selection,record,source_path,archive=self._native_input
        now,_zone=self.gate._wall_clock()
        validate_record(self.bundle,self.grant,_NativeEvidence(self.evidence),selection,body,record,source_path,now,archive=archive)

    def _check_audit(self,phase,gate_receipt):
        packet,receipt,state,current=self.audit_store.inspect(self.bundle,self.grant,self.gate)
        if packet!=self._packet or receipt!=self.audit_receipt or state['phase']!=phase or current!=gate_receipt:
            raise ValueError('independent_supervisor/audit_changed')

    def _before_claim(self,reserved):
        self._check_native();self._check_evidence()
        self.audit_receipt=self.audit_store.seal(self.bundle,self.grant,self.gate,self.evidence,
                                                 include_components=self._include_components)
        self._check_audit('prepared',reserved)
        self._check_evidence();self._check_native()

    def _before_release(self):
        self._check_audit('claimed',self.dispatch_receipt)
        self._check_evidence();self._check_native()
