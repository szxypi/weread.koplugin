"""Private CB baseline survives ambiguity and cannot declare an unreceived ACK."""
from copy import deepcopy
import unittest
from unittest.mock import patch

import cb_native_time_bundle_audit_store as module
from cb_native_readtime_model import batch
from cb_native_time_bundle_audit_store import AuditStore,SERVICE
from cb_native_time_bundle_gate import DispatchGate,SERVICE as GATE_SERVICE
from secure_weread_session import StoreError
from test_cb_native_time_bundle_accounting import example
from test_secure_native_session import Backend


def setup():
    bundle,grant,before,samples,now=example();plan=bundle['plan'];snapshot=before['snapshot']
    rows=[{key:row[key] for key in ('start_time','duration','time_zone','book_version')} for row in plan['rows']]
    body=batch(grant,plan['book_id'],rows,'synthetic-guest','synthetic-config',now,123,now*1000,456,
               current_zone='+08:00',summary=snapshot['native']['summary']['value'])
    gate=DispatchGate(Backend(),clock=lambda:now,zone=lambda:'+08:00')
    store=AuditStore(Backend(),clock=lambda:now)
    return bundle,grant,before,samples,now,body,gate,store


class ImportedAuditStoreTests(unittest.TestCase):
    def test_seal_then_acknowledge_and_independent_audit(self):
        bundle,grant,before,samples,now,body,gate,store=setup()
        self.assertNotEqual(SERVICE,GATE_SERVICE)
        with self.assertRaises(ValueError):store.seal(bundle,grant,gate,before['snapshot'],before['months'],now)
        reserved=gate.reserve(bundle,grant,before['snapshot'])
        receipt=store.seal(bundle,grant,gate,before['snapshot'],before['months'],now)
        self.assertEqual(store.inspect(bundle,grant,gate)[1],receipt)
        with self.assertRaises(StoreError):store.seal(bundle,grant,gate,before['snapshot'],before['months'],now)
        claimed=gate.claim(reserved,bundle,grant,before['snapshot'],body,'synthetic-guest','synthetic-config')
        with self.assertRaises(ValueError):store.check_acknowledged(bundle,grant,gate,samples)
        gate.acknowledge(claimed,{'succ':1})
        result=store.check_acknowledged(bundle,grant,gate,samples)
        self.assertEqual(result['result'],'ACCOUNTING_MATCH');self.assertFalse(result['real_accounting_verified'])
        self.assertEqual(store.read()[1],receipt)
        for name in ('send','claim','advance','delete','reset'):self.assertFalse(hasattr(store,name))
    def test_no_ack_and_changed_observation_remain_unverified(self):
        bundle,grant,before,samples,now,body,gate,store=setup();reserved=gate.reserve(bundle,grant,before['snapshot'])
        store.seal(bundle,grant,gate,before['snapshot'],before['months'],now)
        claimed=gate.claim(reserved,bundle,grant,before['snapshot'],body,'synthetic-guest','synthetic-config')
        with self.assertRaises(ValueError):store.check_acknowledged(bundle,grant,gate,samples)
        self.assertEqual(gate.read()[0]['phase'],'claimed')
        gate.acknowledge(claimed,{'succ':1});bad=deepcopy(samples);bad[2]['snapshot']['web']['summary']['value']='changed'
        with self.assertRaises(ValueError):store.check_acknowledged(bundle,grant,gate,bad)
        self.assertEqual(gate.read()[0]['phase'],'acknowledged')
    def test_renewal_allows_readback_only_and_corruption_fails(self):
        bundle,grant,before,samples,now,body,gate,store=setup();reserved=gate.reserve(bundle,grant,before['snapshot'])
        store.seal(bundle,grant,gate,before['snapshot'],before['months'],now)
        claimed=gate.claim(reserved,bundle,grant,before['snapshot'],body,'synthetic-guest','synthetic-config');gate.acknowledge(claimed,{'succ':1})
        refreshed=dict(grant,accessToken='renewed-synthetic-token')
        self.assertEqual(store.check_acknowledged(bundle,refreshed,gate,samples)['result'],'ACCOUNTING_MATCH')
        with self.assertRaises(StoreError):gate.assert_claim_current(claimed,bundle,refreshed,before['snapshot'],body,'synthetic-guest','synthetic-config')
        store.backend.data=b'{}'
        with self.assertRaises(StoreError):store.read()
    def test_keychain_clock_and_lock_cannot_be_overridden(self):
        class FakeMac(Backend):pass
        with patch.object(module,'MacKeychain',FakeMac):
            with self.assertRaises(ValueError):AuditStore(FakeMac(),clock=lambda:1)
            with self.assertRaises(ValueError):AuditStore(FakeMac(),lock=lambda:None)
            store=AuditStore(FakeMac());store.clock=lambda:1
            with self.assertRaises(ValueError):store._now()


if __name__=='__main__':unittest.main()
