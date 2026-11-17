"""Private bridge grants one request only after exact durable checks."""
import base64
from copy import deepcopy
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock,patch

from native_time_bundle_audit_store import AuditStore
from native_time_bundle_bridge import NativeTimeBridge
from native_time_bundle_selection import expected
from native_time_bundle_supervisor import NativeBoundSupervisor
from secure_highlight_trial import Receipt
from test_native_time_bundle_evidence import evidence_fixture
from test_native_time_bundle_gate import fixture,gate
from test_native_time_bundle_native_record import make_record
from test_secure_native_session import Backend


def setup(armed=False):
    bundle,grant,before,_report,now,evidence=evidence_fixture();_b,_g,body,_n=fixture()
    folder=tempfile.TemporaryDirectory();path=Path(folder.name)/'source.epub'
    path.write_bytes(base64.b64decode(bundle['plan']['archive_base64']))
    selection=expected(bundle);record=make_record(bundle,grant,before,body,path)
    keeper=gate(now);store=Mock();store.read.return_value=(bundle,Receipt(b'synthetic-capture'))
    audit=AuditStore(Backend(),clock=lambda:now)
    guard=NativeBoundSupervisor(keeper,store,bundle,grant,'synthetic-guest','synthetic-config',lambda:True,audit_store=audit,evidence=evidence)
    guard.prepare();bridge=NativeTimeBridge(guard,path,armed=armed)
    return folder,keeper,audit,guard,bridge,{'kind':'selection','selection':selection},dict(kind='claim',body=body,selection=selection,record=record)


class BridgeTests(unittest.TestCase):
    def test_requires_bound_guard_and_explicit_boolean_mode(self):
        folder,keeper,_audit,guard,_bridge,_selection,_claim=setup();self.addCleanup(folder.cleanup)
        for bad_guard,armed in ((Mock(),True),(guard,1),(guard,None)):
            with self.subTest(armed=armed),self.assertRaisesRegex(ValueError,'native_bridge/mode'):
                NativeTimeBridge(bad_guard,Path(folder.name)/'source.epub',armed=armed)
        self.assertEqual(keeper.read(),(None,None))

    def test_default_preview_validates_but_never_reserves_or_releases(self):
        folder,keeper,audit,_guard,bridge,selection,claim=setup();self.addCleanup(folder.cleanup)
        self.assertTrue(bridge.handle(selection));self.assertFalse(bridge.handle(claim))
        self.assertEqual(bridge.phase,'preview_blocked');self.assertEqual(keeper.read(),(None,None));self.assertEqual(audit.read(),(None,None))
        with self.assertRaises(ValueError):bridge.handle(claim)
        self.assertEqual(keeper.read(),(None,None))

    def test_armed_permission_follows_durable_claim_and_valid_http_receipt(self):
        folder,keeper,audit,_guard,bridge,selection,claim=setup(True);self.addCleanup(folder.cleanup)
        self.assertTrue(bridge.handle(selection));self.assertTrue(bridge.handle(claim))
        self.assertEqual(keeper.read()[0]['phase'],'claimed');self.assertEqual(audit.read()[0]['phase'],'baseline')
        self.assertTrue(bridge.handle({'kind':'ack','status':200,'response':{'succ':1}}))
        self.assertEqual(keeper.read()[0]['phase'],'acknowledged')
        with self.assertRaises(ValueError):bridge.handle(claim)
        self.assertEqual(keeper.read()[0]['phase'],'acknowledged')

    def test_invalid_or_duplicate_receipts_never_advance_or_replay(self):
        for status,response in ((201,{'succ':1}),(True,{'succ':1}),(200,{'succ':0}),(200,{'succ':1,'errcode':-1}),(200,{})):
            folder,keeper,_audit,_guard,bridge,selection,claim=setup(True);self.addCleanup(folder.cleanup)
            bridge.handle(selection);bridge.handle(claim)
            with self.subTest(status=status,response=response),self.assertRaisesRegex(ValueError,'native_bridge/receipt'):
                bridge.handle({'kind':'ack','status':status,'response':response})
            self.assertEqual(keeper.read()[0]['phase'],'claimed')
            with self.assertRaises(ValueError):bridge.handle({'kind':'ack','status':200,'response':{'succ':1}})
            self.assertEqual(keeper.read()[0]['phase'],'claimed')

    def test_wrong_order_or_changed_record_never_reserves(self):
        for mode in ('early_ack','changed','extra'):
            folder,keeper,_audit,_guard,bridge,selection,claim=setup(True);self.addCleanup(folder.cleanup)
            if mode!='early_ack':bridge.handle(selection)
            if mode=='changed':claim=deepcopy(claim);claim['record']['metadata']['counts']['ttsTime']+=1
            if mode=='extra':claim=dict(claim,extra=True)
            with self.subTest(mode=mode),self.assertRaises(ValueError):
                bridge.handle({'kind':'ack','status':200,'response':{'succ':1}} if mode=='early_ack' else claim)
            self.assertEqual(keeper.read(),(None,None))
            with self.assertRaises(ValueError):bridge.handle(selection)

    def test_failed_release_keeps_claim_and_stops_the_bridge(self):
        folder,keeper,_audit,guard,bridge,selection,claim=setup(True);self.addCleanup(folder.cleanup)
        bridge.handle(selection)
        with patch.object(guard,'_before_release',side_effect=ValueError('synthetic_failure')):
            with self.assertRaises(ValueError):bridge.handle(claim)
        self.assertEqual(keeper.read()[0]['phase'],'claimed');self.assertEqual(bridge.phase,'stopped')
        with self.assertRaises(ValueError):bridge.handle(claim)


if __name__=='__main__':unittest.main()
