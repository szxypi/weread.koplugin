"""Read two signing inputs after an unchanged private CB preflight; no writes."""
from annotation_experiment_model import digest
from cb_native_time_bundle_gate import binding
from cb_native_time_bundle_preflight import Prepared
from native_time_bundle_preparation import SigningInputs,SigningRead
from secure_weread_session import MacKeychain
import time


def read_inputs(prepared,store,gate,audit,current,*,clock=time.time,probe_factory=SigningRead):
    if not isinstance(prepared,Prepared) or not callable(current):raise ValueError('cb_preparation/input')
    real=any(isinstance(getattr(item,'backend',None),MacKeychain) for item in (store,gate,audit))
    if real and (clock is not time.time or probe_factory is not SigningRead):raise ValueError('cb_preparation/override')
    bundle,receipt,grant,evidence=prepared.bundle,prepared.receipt,prepared.grant,prepared.evidence
    initial=digest((bundle,grant));report,snapshot,months=evidence.for_bundle(bundle,grant)
    evidence_hash=digest((report,snapshot,months))
    def fresh():
        return (current() is True and store.read()==(bundle,receipt) and gate.read()==(None,None) and audit.read()==(None,None)
                and digest((bundle,grant))==initial and digest(evidence.for_bundle(bundle,grant))==evidence_hash)
    def recent():
        now=int(clock());binding(bundle,grant,snapshot,now)
        return 0<=now-report['completed_at']<30
    if not fresh() or not recent():raise ValueError('cb_preparation/stale')
    probe=probe_factory(grant,fresh)
    try:inputs=probe.read()
    finally:
        value=getattr(probe,'grant',None)
        if isinstance(value,dict):value.clear()
    if not isinstance(inputs,SigningInputs) or not fresh() or not recent():raise ValueError('cb_preparation/stale')
    return inputs
