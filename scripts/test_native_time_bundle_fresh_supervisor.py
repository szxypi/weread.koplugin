"""Fresh supervisor binds the native request, journals and durable baseline."""
import base64
from copy import deepcopy
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock,patch

from native_time_bundle_bridge import NativeTimeBridge
from native_time_bundle_fresh_audit import FreshAuditStore
from native_time_bundle_fresh_supervisor import FreshNativeBoundSupervisor
from native_time_bundle_preparation import SigningInputs,read_fresh_evidenced_signing_inputs
from native_time_bundle_selection import expected
from secure_highlight_trial import Receipt
from test_native_time_bundle_accounting import example as accounting_example
from test_native_time_bundle_evidence import synthetic_scope
from test_native_time_bundle_fresh_shelf import example as shelf_example
from test_native_time_bundle_gate import fixture,gate
from test_native_time_bundle_native_record import make_record
from test_secure_native_session import Backend


class FreshSupervisorTests(unittest.TestCase):
    def setUp(self):
        folder=tempfile.TemporaryDirectory();self.addCleanup(folder.cleanup)
        self.bundle,self.grant,self.evidence,self.observations=shelf_example()
        _b,_g,self.before,self.samples,self.now=accounting_example();_b,_g,self.body,_n=fixture()
        self.path=Path(folder.name)/'source.epub'
        self.path.write_bytes(base64.b64decode(self.bundle['plan']['archive_base64']))
        self.selection=expected(self.bundle)
        self.record=make_record(self.bundle,self.grant,self.before,self.body,self.path)
        self.keeper=gate(self.now);self.store=Mock();self.store.read.return_value=(self.bundle,Receipt(b'synthetic-capture'))
        self.audit=FreshAuditStore(Backend(),clock=lambda:self.now)
        self.trial=synthetic_scope(self.bundle);self.trial_reader=Mock(side_effect=lambda:deepcopy(self.trial))
        self.guard=FreshNativeBoundSupervisor(self.keeper,self.store,self.bundle,self.grant,'synthetic-guest','synthetic-config',
                    lambda:True,audit_store=self.audit,evidence=self.evidence,trial_reader=self.trial_reader)

    def test_preview_then_single_claim_acknowledgement_and_readback(self):
        self.guard.prepare();self.guard.select(self.selection)
        self.assertTrue(self.guard.preview(self.body,self.selection,self.record,self.path))
        self.assertEqual(self.keeper.read(),(None,None));self.assertEqual(self.audit.read(),(None,None))
        self.guard.claim(self.body,self.selection,self.record,self.path)
        packet,_receipt,state,_gate=self.audit.inspect(self.bundle,self.grant,self.keeper)
        self.assertEqual(state['phase'],'claimed');self.assertFalse(packet['report']['previous_native_group_baseline_matches'])
        self.guard.acknowledge({'succ':1})
        result=self.audit.check_acknowledged(self.bundle,self.grant,self.keeper,self.samples,self.trial,self.observations)
        self.assertEqual(result['result'],'ACCOUNTING_MATCH');self.assertFalse(result['real_accounting_verified'])
        with self.assertRaises(ValueError):self.guard.claim(self.body,self.selection,self.record,self.path)

    def test_bridge_accepts_guard_but_dry_run_never_reserves(self):
        self.guard.prepare();bridge=NativeTimeBridge(self.guard,self.path,armed=False)
        self.assertTrue(bridge.handle({'kind':'selection','selection':self.selection}))
        self.assertFalse(bridge.handle({'kind':'claim','body':self.body,'selection':self.selection,'record':self.record}))
        self.assertEqual(self.keeper.read(),(None,None));self.assertEqual(self.audit.read(),(None,None))

    def test_signing_preparation_requires_unchanged_evidence_and_trial(self):
        for changed in (False,True):
            with self.subTest(changed=changed):
                self.setUp();probe=Mock()
                def read():
                    if changed:self.trial['old_sha256']='c'*64
                    return SigningInputs('synthetic-guest','synthetic-config')
                probe.read.side_effect=read
                args=dict(bundle=self.bundle,receipt=self.store.read()[1],grant=self.grant,store=self.store,
                          gate=self.keeper,current=lambda:True,evidence=self.evidence,trial_reader=self.trial_reader,
                          probe=probe,clock=lambda:self.now)
                if changed:
                    with self.assertRaises(ValueError):read_fresh_evidenced_signing_inputs(**args)
                else:self.assertEqual(read_fresh_evidenced_signing_inputs(**args),SigningInputs('synthetic-guest','synthetic-config'))
                self.assertEqual(self.keeper.read(),(None,None));self.assertEqual(self.audit.read(),(None,None))

    def test_journal_change_before_or_during_reservation_never_releases_claim(self):
        for stage in ('before','during'):
            with self.subTest(stage=stage):
                self.setUp();self.guard.prepare();self.guard.select(self.selection)
                reserve=self.keeper.reserve
                if stage=='before':self.trial['old_sha256']='c'*64
                def change(*args,**kwargs):
                    receipt=reserve(*args,**kwargs);self.trial['old_sha256']='c'*64;return receipt
                with patch.object(self.keeper,'reserve',side_effect=change if stage=='during' else reserve):
                    with self.assertRaises(ValueError):self.guard.claim(self.body,self.selection,self.record,self.path)
                state,_=self.keeper.read()
                self.assertEqual(state['phase'] if state else None,'prepared' if stage=='during' else None)
                self.assertEqual(self.audit.read(),(None,None))

    def test_evidence_change_after_claim_does_not_release_permission_or_retry(self):
        self.guard.prepare();self.guard.select(self.selection);claim=self.keeper.claim
        def change(*args,**kwargs):
            receipt=claim(*args,**kwargs)
            self.evidence._value=(*self.evidence._value[:3],('c'*64,'d'*64),self.evidence._value[4])
            return receipt
        with patch.object(self.keeper,'claim',side_effect=change):
            with self.assertRaises(ValueError):self.guard.claim(self.body,self.selection,self.record,self.path)
        self.assertEqual(self.keeper.read()[0]['phase'],'claimed');self.assertEqual(self.audit.read()[0]['phase'],'baseline')
        with self.assertRaises(ValueError):self.guard.claim(self.body,self.selection,self.record,self.path)


if __name__=='__main__':unittest.main()
