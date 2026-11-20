"""An independent worker can be previewed, claimed and audited exactly once."""
import base64
from copy import deepcopy
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock,patch

from native_time_bundle_bridge import NativeTimeBridge
from native_time_bundle_selection import expected
from native_time_independent_supervisor import IndependentNativeBoundSupervisor
from secure_highlight_trial import Receipt
from secure_weread_session import StoreError
from test_native_time_bundle_native_record import make_record
from test_native_time_independent_audit import fixture


class IndependentSupervisorTests(unittest.TestCase):
    def setUp(self):
        folder=tempfile.TemporaryDirectory();self.addCleanup(folder.cleanup)
        (self.bundle,self.grant,self.body,self.now,self.before,self.evidence,self.gate,self.audit,
         self.samples,self.observations)=fixture()
        self.path=Path(folder.name)/'source.epub';self.path.write_bytes(base64.b64decode(self.bundle['plan']['archive_base64']))
        self.selection=expected(self.bundle)
        self.record=make_record(self.bundle,self.grant,self.before,self.body,self.path)
        self.store=Mock();self.store.read.return_value=(self.bundle,Receipt(b'synthetic-capture'))
        self.current=Mock(return_value=True)
        self.guard=IndependentNativeBoundSupervisor(self.gate,self.store,self.bundle,self.grant,
            'synthetic-guest','synthetic-config',self.current,audit_store=self.audit,evidence=self.evidence)

    def test_native_preview_does_not_claim_and_bridge_denies_send(self):
        self.guard.prepare();bridge=NativeTimeBridge(self.guard,self.path,armed=False)
        self.assertTrue(bridge.handle({'kind':'selection','selection':self.selection}))
        self.assertFalse(bridge.handle({'kind':'claim','body':self.body,'selection':self.selection,'record':self.record}))
        self.assertEqual(self.gate.read(),(None,None));self.assertEqual(self.audit.read(),(None,None))

    def test_claim_seals_matching_baseline_before_permission_then_requires_readback(self):
        self.guard.prepare();bridge=NativeTimeBridge(self.guard,self.path,armed=True)
        self.assertTrue(bridge.handle({'kind':'selection','selection':self.selection}))
        self.assertTrue(bridge.handle({'kind':'claim','body':self.body,'selection':self.selection,'record':self.record}))
        packet,_receipt,state,_gate=self.audit.inspect(self.bundle,self.grant,self.gate)
        self.assertEqual(state['phase'],'claimed');self.assertEqual(packet['baseline'],self.before)
        self.assertTrue(bridge.handle({'kind':'ack','status':200,'response':{'succ':1}}))
        result=self.audit.check_acknowledged(self.bundle,self.grant,self.gate,self.samples,self.observations)
        self.assertEqual(result['result'],'ACCOUNTING_MATCH');self.assertFalse(result['real_accounting_verified'])
        with self.assertRaises(ValueError):bridge.handle({'kind':'claim','body':self.body,'selection':self.selection,'record':self.record})

    def test_legacy_or_mixed_journals_and_changed_capture_rejected(self):
        from native_time_bundle_fresh_audit import FreshAuditStore
        from test_secure_native_session import Backend
        with self.assertRaises(ValueError):
            IndependentNativeBoundSupervisor(self.gate,self.store,self.bundle,self.grant,'guest','config',self.current,
                audit_store=FreshAuditStore(Backend(),clock=lambda:self.now),evidence=self.evidence)
        self.gate.capture.bundle['plan']['seconds']+=1
        with self.assertRaises((ValueError,StoreError)):self.guard.prepare()
        self.assertEqual(self.gate.read(),(None,None));self.assertEqual(self.audit.read(),(None,None))

    def test_cancel_or_tampering_at_claim_boundaries_does_not_release_permission(self):
        for stage in ('before','during_reserve','during_claim','archive','receipt'):
            with self.subTest(stage=stage):
                self.setUp();self.guard.prepare();self.guard.select(self.selection)
                reserve=self.gate.reserve;claim=self.gate.claim
                if stage=='before':self.current.return_value=False
                if stage=='archive':self.path.write_bytes(b'replaced')
                if stage=='receipt':self.store.read.return_value=(self.bundle,Receipt(b'new-receipt'))
                def changed_reserve(*args,**kwargs):
                    value=reserve(*args,**kwargs);self.current.return_value=False;return value
                def changed_claim(*args,**kwargs):
                    value=claim(*args,**kwargs);self.current.return_value=False;return value
                with patch.object(self.gate,'reserve',side_effect=changed_reserve if stage=='during_reserve' else reserve), \
                     patch.object(self.gate,'claim',side_effect=changed_claim if stage=='during_claim' else claim):
                    with self.assertRaises(ValueError):self.guard.claim(self.body,self.selection,self.record,self.path)
                state,_=self.gate.read();phase=state['phase'] if state else None
                self.assertEqual(phase,'prepared' if stage=='during_reserve' else 'claimed' if stage=='during_claim' else None)
                if stage=='during_claim':
                    self.assertEqual(self.audit.read()[0]['phase'],'baseline')
                    with self.assertRaises(ValueError):self.guard.claim(self.body,self.selection,self.record,self.path)
                else:self.assertEqual(self.audit.read(),(None,None))

    def test_evidence_mutation_is_rejected_before_and_after_claim(self):
        self.guard.prepare();self.guard.select(self.selection);claim=self.gate.claim
        def change(*args,**kwargs):
            receipt=claim(*args,**kwargs)
            self.evidence._value=(*self.evidence._value[:3],('c'*64,'d'*64),self.evidence._value[4])
            return receipt
        with patch.object(self.gate,'claim',side_effect=change):
            with self.assertRaises(ValueError):self.guard.claim(self.body,self.selection,self.record,self.path)
        self.assertEqual(self.gate.read()[0]['phase'],'claimed');self.assertEqual(self.audit.read()[0]['phase'],'baseline')


if __name__=='__main__':unittest.main()
