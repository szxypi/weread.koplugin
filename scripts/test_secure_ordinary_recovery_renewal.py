import copy
import json
import unittest

from secure_ordinary_recovery_renewal import RecoveryRenewalStore,RetryRecoveryRenewalStore,ThirdRecoveryRenewalStore
from secure_weread_session import StoreError
from test_secure_native_session import Backend


def binding():return dict(original_intent_sha256='a'*64,owner_sha256='b'*64,device_sha256='c'*64,old_grant_sha256='d'*64)


class RenewalBridgeTests(unittest.TestCase):
    def test_one_claim_is_durable_and_cannot_repeat(self):
        backend=Backend();store=RecoveryRenewalStore(backend);receipt=store.reserve(binding());pending=store.claim(receipt)
        with self.assertRaises(StoreError):store.claim(receipt)
        with self.assertRaises(StoreError):store.reserve(binding())
        done=store.finish(pending,'e'*64)
        self.assertEqual(RecoveryRenewalStore(backend).read()[1],done)
        with self.assertRaises(StoreError):store.finish(pending,'e'*64)
    def test_corrupt_or_unbound_state_fails_closed(self):
        store=RecoveryRenewalStore(Backend());bad=binding();bad['old_grant_sha256']='bad'
        with self.assertRaises(StoreError):store.reserve(bad)
        store.reserve(binding());value=json.loads(store.backend.data)
        for key,bad in [('scope','wrong'),('new_grant_sha256','e'*64),('schema',True)]:
            item=copy.deepcopy(value);item[key]=bad;store.backend.data=json.dumps(item).encode()
            with self.assertRaises(StoreError):store.read()

    def test_retry_renewal_has_a_separate_scope(self):
        first=RecoveryRenewalStore(Backend());retry=RetryRecoveryRenewalStore(Backend())
        self.assertNotEqual(first.service,retry.service);self.assertNotEqual(first.lock_name,retry.lock_name)
        first.reserve(binding());retry.reserve(binding())
        self.assertNotEqual(first.backend.data,retry.backend.data)

    def test_third_renewal_is_separate_and_single_use(self):
        second=RetryRecoveryRenewalStore(Backend());third=ThirdRecoveryRenewalStore(Backend())
        self.assertNotEqual(second.service,third.service);self.assertNotEqual(second.lock_name,third.lock_name)
        second.reserve(binding());old=second.backend.data
        receipt=third.reserve(binding());third.claim(receipt)
        self.assertEqual(second.backend.data,old)
        with self.assertRaises(StoreError):third.claim(receipt)


if __name__=='__main__':unittest.main()
