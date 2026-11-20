"""Private baselines remain immutable and never grant replay or accounting."""
from copy import deepcopy
import unittest
from unittest.mock import patch

from native_time_bundle_audit_store import AuditStore
from secure_weread_session import StoreError
from test_native_time_bundle_accounting import example
from test_native_time_bundle_gate import fixture,gate
from test_secure_native_session import Backend


def setup():
    bundle,grant,before,samples,now=example();_same,_grant,body,_same_now=fixture()
    gatekeeper=gate(now);reservation=gatekeeper.reserve(bundle,grant)
    store=AuditStore(Backend(),clock=lambda:now)
    return bundle,grant,before,samples,now,body,gatekeeper,reservation,store


class BundleAuditStoreTests(unittest.TestCase):
    def test_baseline_is_immutable_and_explicit_ack_does_not_prove_accounting(self):
        bundle,grant,before,samples,now,body,gatekeeper,reservation,store=setup()
        receipt=store.seal(bundle,grant,gatekeeper,before['snapshot'],before['months'],now)
        saved,saved_receipt,state,_=store.inspect(bundle,grant,gatekeeper)
        self.assertEqual(saved,before);self.assertEqual(saved_receipt,receipt);self.assertEqual(state['phase'],'prepared')
        with self.assertRaises(ValueError):store.check_acknowledged(bundle,grant,gatekeeper,samples)
        with self.assertRaises(StoreError):store.seal(bundle,grant,gatekeeper,before['snapshot'],before['months'],now)
        claimed=gatekeeper.claim(reservation,bundle,grant,body,'synthetic-guest','synthetic-config')
        with self.assertRaises(ValueError):store.check_acknowledged(bundle,grant,gatekeeper,samples)
        gatekeeper.acknowledge(claimed,{'succ':1})
        result=store.check_acknowledged(bundle,grant,gatekeeper,samples)
        self.assertEqual(result['result'],'ACCOUNTING_MATCH');self.assertFalse(result['real_accounting_verified'])
        self.assertEqual(store.read()[1],receipt)
        with self.assertRaises(ValueError):store.seal(bundle,grant,gatekeeper,before['snapshot'],before['months'],now)
        for name in ('send','post','claim','advance','delete','verify'):self.assertFalse(hasattr(store,name))

    def test_prepared_gate_and_original_baseline_are_required(self):
        for mode in ('gate_missing','gate_claimed','position','stats','stale','foreign'):
            bundle,grant,before,_samples,now,body,gatekeeper,reservation,store=setup()
            snapshot=deepcopy(before['snapshot']);months=deepcopy(before['months']);stamp=now
            if mode=='gate_missing':gatekeeper=gate(now)
            elif mode=='gate_claimed':gatekeeper.claim(reservation,bundle,grant,body,'synthetic-guest','synthetic-config')
            elif mode=='position':snapshot['point']['chapter_offset']+=1
            elif mode=='stats':months={}
            elif mode=='stale':stamp=now-30
            else:grant['deviceId']='eink334691225'+'2'*19
            with self.subTest(mode=mode),self.assertRaises((ValueError,StoreError)):
                store.seal(bundle,grant,gatekeeper,snapshot,months,stamp)
            self.assertEqual(store.read(),(None,None))

    def test_after_ack_same_device_renewal_may_only_read_and_compare(self):
        bundle,grant,before,samples,now,body,gatekeeper,reservation,store=setup()
        store.seal(bundle,grant,gatekeeper,before['snapshot'],before['months'],now)
        claimed=gatekeeper.claim(reservation,bundle,grant,body,'synthetic-guest','synthetic-config');gatekeeper.acknowledge(claimed,{'succ':1})
        grant['accessToken']='renewed-synthetic-token'
        self.assertEqual(store.check_acknowledged(bundle,grant,gatekeeper,samples)['result'],'ACCOUNTING_MATCH')
        grant['deviceId']='eink334691225'+'2'*19
        with self.assertRaises(ValueError):store.check_acknowledged(bundle,grant,gatekeeper,samples)
        self.assertEqual(gatekeeper.read()[0]['phase'],'acknowledged')

    def test_ambiguous_saved_baseline_is_never_overwritten(self):
        bundle,grant,before,_samples,now,_body,gatekeeper,_reservation,store=setup();save=store.backend.save
        def save_then_fail(raw):save(raw);raise StoreError('synthetic_failure')
        with patch.object(store.backend,'save',side_effect=save_then_fail),self.assertRaises(StoreError):
            store.seal(bundle,grant,gatekeeper,before['snapshot'],before['months'],now)
        self.assertEqual(store.read()[0]['phase'],'baseline')
        with self.assertRaises(StoreError):store.seal(bundle,grant,gatekeeper,before['snapshot'],before['months'],now)

    def test_gate_changes_during_save_are_detected_and_both_records_retained(self):
        bundle,grant,before,_samples,now,body,gatekeeper,reservation,store=setup();save=store.backend.save
        def save_then_claim(raw):
            save(raw);gatekeeper.claim(reservation,bundle,grant,body,'synthetic-guest','synthetic-config')
        with patch.object(store.backend,'save',side_effect=save_then_claim),self.assertRaises(StoreError):
            store.seal(bundle,grant,gatekeeper,before['snapshot'],before['months'],now)
        self.assertEqual(store.read()[0]['phase'],'baseline');self.assertEqual(gatekeeper.read()[0]['phase'],'claimed')

    def test_changed_gate_attempt_or_unstable_observation_fails(self):
        bundle,grant,before,samples,now,body,gatekeeper,reservation,store=setup()
        store.seal(bundle,grant,gatekeeper,before['snapshot'],before['months'],now)
        claimed=gatekeeper.claim(reservation,bundle,grant,body,'synthetic-guest','synthetic-config');gatekeeper.acknowledge(claimed,{'succ':1})
        samples[-1]['snapshot']['counts']['ttsTime']=1
        with self.assertRaises(ValueError):store.check_acknowledged(bundle,grant,gatekeeper,samples)
        other=gate(now);other.reserve(bundle,grant)
        with self.assertRaises(ValueError):store.inspect(bundle,grant,other)
        self.assertEqual(store.read()[0]['phase'],'baseline');self.assertEqual(gatekeeper.read()[0]['phase'],'acknowledged')


if __name__=='__main__':unittest.main()
