"""Native one-shot supervisor for a separately sealed fresh shelf baseline.

It does not perform transport. Callers must provide a fresh scoped preflight,
authenticated journal reader and a bounded native worker, as for the original
supervisor. The old trial's status is retained verbatim, never called restored.
"""
from copy import deepcopy

from annotation_experiment_model import digest
from native_time_bundle_accounting import baseline
from native_time_bundle_evidence import FreshShelfEvidence
from native_time_bundle_fresh_audit import FreshAuditStore,MAX_RECORD_BYTES,packet_size
from native_time_bundle_native_record import validate_record
from native_time_bundle_supervisor import NativeBoundSupervisor,Supervisor
from native_time_bundle_fresh_audit import SERVICE as FRESH_SERVICE
from native_time_bundle_trial_scope import LiveTrialReader
from secure_weread_session import MacKeychain


class _NativeEvidence:
    def __init__(self,evidence):self.evidence=evidence
    def for_bundle(self,bundle,grant):return self.evidence.for_bundle(bundle,grant)[:3]
    def catalog_stamp(self,bundle,grant):return self.evidence.for_bundle(bundle,grant)[3]


class FreshNativeBoundSupervisor(NativeBoundSupervisor):
    def __init__(self,gate,store,bundle,grant,guest,config_token,current,*,audit_store,evidence,trial_reader):
        if (not isinstance(audit_store,FreshAuditStore) or not isinstance(evidence,FreshShelfEvidence)
                or not callable(trial_reader)):
            raise ValueError('fresh_supervisor/evidence')
        if (isinstance(audit_store.backend,MacKeychain) and audit_store.backend.service==FRESH_SERVICE
                and not isinstance(trial_reader,LiveTrialReader)):
            raise ValueError('fresh_supervisor/trial_reader')
        report,snapshot,months,stamp,shelves,trial=evidence.for_bundle(bundle,grant)
        self.evidence,self.audit_store,self.trial_reader=evidence,audit_store,trial_reader
        self.snapshot,self.months=deepcopy(snapshot),deepcopy(months)
        self._packet={'report':report,'baseline':baseline(bundle,grant,snapshot,months,report['completed_at']),
                      'catalog_stamp':stamp,'shelves':list(shelves),'trial_scope':trial}
        components=evidence.components_for_bundle(bundle,grant)
        self._include_components=components is not None
        if self._include_components:
            self._packet['components']=list(components);self._packet['components_sha256']=digest(components)
            if packet_size(self._packet)>MAX_RECORD_BYTES:
                self._packet.pop('components');self._packet.pop('components_sha256');self._include_components=False
        if packet_size(self._packet)>MAX_RECORD_BYTES:raise ValueError('fresh_supervisor/audit_size')
        self.audit_receipt=None
        Supervisor.__init__(self,gate,store,bundle,grant,guest,config_token,current,
                            lambda:self.evidence.for_bundle(self.bundle,self.grant)[0])

    def _fresh(self):
        return super()._fresh() and self.trial_reader()==self._packet['trial_scope']

    def _valid_observed(self,observed,now):
        # FreshShelfEvidence revalidates every field and its private bindings.
        report=self.evidence.for_bundle(self.bundle,self.grant)[0]
        return observed==report and 0<=now-report['completed_at']<30

    def _check_evidence(self):
        report,snapshot,months,stamp,shelves,trial=self.evidence.for_bundle(self.bundle,self.grant)
        packet={'report':report,'baseline':baseline(self.bundle,self.grant,snapshot,months,report['completed_at']),
                'catalog_stamp':stamp,'shelves':list(shelves),'trial_scope':trial}
        components=self.evidence.components_for_bundle(self.bundle,self.grant)
        if self._include_components:
            if components is None:raise ValueError('fresh_supervisor/evidence_changed')
            packet['components']=list(components);packet['components_sha256']=digest(components)
        if packet!=self._packet or report['completed_at']!=self.preflight_at or self.trial_reader()!=trial:
            raise ValueError('fresh_supervisor/evidence_changed')

    def _check_native(self):
        body,selection,record,source_path,archive=self._native_input
        now,_zone=self.gate._wall_clock()
        validate_record(self.bundle,self.grant,_NativeEvidence(self.evidence),selection,body,record,source_path,now,archive=archive)

    def _check_fresh_audit(self,phase,gate_receipt):
        packet,receipt,state,current=self.audit_store.inspect(self.bundle,self.grant,self.gate)
        if (packet!=self._packet or receipt!=self.audit_receipt or state['phase']!=phase or current!=gate_receipt):
            raise ValueError('fresh_supervisor/audit_changed')

    def _before_claim(self,reserved):
        self._check_native();self._check_evidence()
        self.audit_receipt=self.audit_store.seal(self.bundle,self.grant,self.gate,self.evidence,self.trial_reader(),
                                                 include_components=self._include_components)
        self._check_fresh_audit('prepared',reserved)
        self._check_evidence();self._check_native()

    def _before_release(self):
        self._check_fresh_audit('claimed',self.dispatch_receipt)
        self._check_evidence();self._check_native()
