"""Synthetic Keychain boundary tests; never accesses actual account data."""
import json
import unittest

from secure_position_experiment import ExperimentStore,ExperimentReceipt,binding,fingerprint,validate_plan
from secure_weread_session import StoreError
from test_position_roundtrip import plan
from test_secure_native_session import Backend


class IntentTests(unittest.TestCase):
    def value(self):return binding('900000',plan(),'a'*64)

    def test_marker_survives_reopen_and_blocks_every_new_plan(self):
        backend=Backend();store=ExperimentStore(backend);value=self.value()
        receipt=store.begin(value)
        self.assertTrue(ExperimentStore(backend).pending())
        with self.assertRaisesRegex(StoreError,'position_experiment_unconfirmed'):ExperimentStore(backend).begin(value)
        self.assertNotIn('900001',repr(receipt))
        self.assertNotIn('synthetic',backend.data.decode())
        self.assertEqual(json.loads(backend.data)['maximum_posts'],4)

    def test_only_owned_proved_resolution_removes_the_temporary_item(self):
        backend=Backend();store=ExperimentStore(backend);receipt=store.begin(self.value())
        with self.assertRaises(StoreError):store.finish(receipt)
        with self.assertRaises(StoreError):store.finish(receipt,restored_verified=True,not_dispatched=True)
        store.finish(receipt,restored_verified=True)
        self.assertFalse(store.pending())
        with self.assertRaises(StoreError):store.finish(receipt,restored_verified=True)

    def test_proved_zero_dispatch_can_release_but_an_old_receipt_cannot(self):
        backend=Backend();store=ExperimentStore(backend);old=store.begin(self.value())
        store.finish(old,not_dispatched=True)
        latest=store.begin(self.value())
        with self.assertRaises(StoreError):store.finish(old,not_dispatched=True)
        self.assertTrue(store.pending());store.finish(latest,not_dispatched=True)

    def test_corruption_is_not_overwritten_and_readback_is_mandatory(self):
        backend=Backend();backend.data=b'invalid-private-marker';store=ExperimentStore(backend)
        with self.assertRaises(StoreError):store.begin(self.value())
        self.assertEqual(backend.data,b'invalid-private-marker')
        backend=Backend();backend.load=lambda:None
        with self.assertRaisesRegex(StoreError,'position_intent_readback_failed'):ExperimentStore(backend).begin(self.value())

    def test_scope_counter_and_hash_validation_are_strict(self):
        value=self.value();base=fingerprint(value)
        for key,bad in (('probe_offset',value['probe_offset']+1),('raw_percent',True),('chapter_idx',-1),
                        ('owner','foreign'),('raw_source_sha256','bad'),('book_id','0')):
            changed=dict(value);changed[key]=bad
            with self.assertRaises(StoreError):validate_plan(changed)
        changed=dict(value,raw_percent=26)
        self.assertNotEqual(fingerprint(changed),base)

    def test_cleanup_readback_failure_is_not_claimed_as_cleared(self):
        backend=Backend();store=ExperimentStore(backend);receipt=store.begin(self.value())
        backend.delete=lambda:True
        with self.assertRaisesRegex(StoreError,'position_intent_cleanup_unverified'):store.finish(receipt,restored_verified=True)
        self.assertTrue(store.pending())
        with self.assertRaises(StoreError):store.finish(ExperimentReceipt(b'foreign'),restored_verified=True)


if __name__=='__main__':unittest.main()
