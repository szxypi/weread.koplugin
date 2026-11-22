import copy
import json
import hashlib
import unittest

from secure_ordinary_partial_recovery import PartialRecoveryStore,RetryPartialRecoveryStore,ThirdPartialRecoveryStore
from secure_weread_session import StoreError
from test_secure_native_session import Backend
from secure_ordinary_reconnect_trial import OrdinaryReconnectStore,OrdinaryReconnectRetryStore,OrdinaryReconnectThirdStore
from test_secure_ordinary_reconnect_trial import plan


def binding():return dict(original_intent_sha256='a'*64,web_shelf_sha256='b'*64,native_shelf_sha256='c'*64,
                          web_shelf_core_sha256='d'*64,native_shelf_core_sha256='e'*64,native_grant_sha256='f'*64,
                          renewal_bridge_sha256='0'*64)


class RecoveryStoreTests(unittest.TestCase):
    def setUp(self):self.backend=Backend();self.store=PartialRecoveryStore(self.backend)
    def test_one_claim_and_durable_retirement(self):
        receipt=self.store.reserve(binding());self.assertTrue(self.store.pending())
        for first,last in (('prepared','pending'),('pending','acknowledged'),('acknowledged','retired')):
            receipt=self.store.advance(receipt,first,last)
            self.assertEqual(PartialRecoveryStore(self.backend).read()[1],receipt)
        self.assertFalse(self.store.pending())
        with self.assertRaises(StoreError):self.store.reserve(binding())
    def test_uncertain_claim_and_stale_receipt_cannot_repeat(self):
        old=self.store.reserve(binding());new=self.store.advance(old,'prepared','pending')
        with self.assertRaises(StoreError):self.store.advance(old,'pending','acknowledged')
        with self.assertRaises(StoreError):self.store.advance(new,'prepared','pending')
        with self.assertRaises(StoreError):self.store.reserve(binding())
        self.assertEqual(self.store.read()[0]['phase'],'pending')
    def test_malformed_binding_and_corrupt_state_fail_closed(self):
        for key,value in [('original_intent_sha256','bad'),('native_shelf_sha256','a'*63)]:
            item=binding();item[key]=value
            with self.assertRaises(StoreError):self.store.reserve(item)
        self.store.reserve(binding());value=json.loads(self.backend.data)
        for key,bad in [('posts',1),('schema',True),('scope','foreign')]:
            item=copy.deepcopy(value);item[key]=bad;self.backend.data=json.dumps(item).encode()
            with self.assertRaises(StoreError):self.store.read()

    def test_original_can_be_sealed_only_by_matching_retired_recovery(self):
        original=OrdinaryReconnectStore(Backend());receipt=original.reserve(plan())
        receipt=original.advance(receipt,'prepared','enter_pending')
        receipt=original.advance(receipt,'enter_pending','enter_acknowledged')
        item=binding();item['original_intent_sha256']=hashlib.sha256(receipt.pending).hexdigest()
        r=self.store.reserve(item)
        with self.assertRaises(StoreError):original.retire_after_partial_recovery(receipt,self.store)
        r=self.store.advance(r,'prepared','pending');r=self.store.advance(r,'pending','acknowledged')
        r=self.store.advance(r,'acknowledged','retired')
        original.retire_after_partial_recovery(receipt,self.store)
        self.assertEqual(original.read()[0]['phase'],'partial_restored');self.assertFalse(original.pending())
        with self.assertRaises(StoreError):original.retire_after_partial_recovery(receipt,self.store)

    def test_retry_recovery_has_a_separate_scope(self):
        retry=RetryPartialRecoveryStore(Backend())
        self.assertNotEqual(self.store.service,retry.service);self.assertNotEqual(self.store.lock_name,retry.lock_name)
        self.store.reserve(binding())
        with self.assertRaises(StoreError):retry.reserve(binding())
        with self.assertRaises(StoreError):retry.reserve(dict(binding(),observed_state='target',original_phase='enter_pending'))
        retry.reserve(dict(binding(),observed_state='entered',original_phase='enter_pending'))
        self.assertNotEqual(self.store.backend.data,retry.backend.data)

    def test_retry_position_phase_requires_matching_retired_recovery(self):
        original=OrdinaryReconnectRetryStore(Backend());receipt=original.reserve(dict(plan(),web_shelf_core_sha256='a'*64,native_shelf_core_sha256='b'*64))
        for before,after in (('prepared','enter_pending'),('enter_pending','enter_acknowledged'),
                             ('enter_acknowledged','enter_verified'),('enter_verified','position_pending')):
            receipt=original.advance(receipt,before,after)
        retry=RetryPartialRecoveryStore(Backend())
        item=dict(binding(),original_intent_sha256=hashlib.sha256(receipt.pending).hexdigest(),observed_state='target',original_phase='position_pending')
        r=retry.reserve(item);r=retry.advance(r,'prepared','pending');r=retry.advance(r,'pending','acknowledged');retry.advance(r,'acknowledged','retired')
        original.retire_after_partial_recovery(receipt,retry)
        self.assertEqual(original.read()[0]['phase'],'partial_restored_after_position');self.assertFalse(original.pending())
        self.assertEqual(original.read()[0]['posts'],2)

    def test_third_scope_requires_its_own_retired_recovery(self):
        original=OrdinaryReconnectThirdStore(Backend());receipt=original.reserve(dict(plan(),web_shelf_core_sha256='a'*64,native_shelf_core_sha256='b'*64))
        receipt=original.advance(receipt,'prepared','enter_pending');receipt=original.advance(receipt,'enter_pending','enter_acknowledged')
        item=dict(binding(),original_intent_sha256=hashlib.sha256(receipt.pending).hexdigest(),observed_state='entered',original_phase='enter_acknowledged')
        wrong=RetryPartialRecoveryStore(Backend());r=wrong.reserve(item)
        for first,last in (('prepared','pending'),('pending','acknowledged'),('acknowledged','retired')):r=wrong.advance(r,first,last)
        with self.assertRaises(StoreError):original.retire_after_partial_recovery(receipt,wrong)
        recovery=ThirdPartialRecoveryStore(Backend());r=recovery.reserve(item)
        for first,last in (('prepared','pending'),('pending','acknowledged'),('acknowledged','retired')):r=recovery.advance(r,first,last)
        original.retire_after_partial_recovery(receipt,recovery)
        self.assertEqual(original.read()[0]['phase'],'partial_restored')
        self.assertNotEqual(original.service,OrdinaryReconnectRetryStore.service)
        self.assertNotEqual(recovery.service,wrong.service)


if __name__=='__main__':unittest.main()
