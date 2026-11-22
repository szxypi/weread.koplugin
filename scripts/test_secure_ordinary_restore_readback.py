import hashlib
import unittest

from secure_ordinary_reconnect_trial import OrdinaryReconnectRetryStore
from secure_ordinary_recovery_renewal import RetryRecoveryRenewalStore
from secure_ordinary_restore_readback import RestoreReadbackStore
from secure_weread_session import StoreError
from test_secure_native_session import Backend
from test_secure_ordinary_reconnect_trial import plan


def retry_plan():return dict(plan(),web_shelf_core_sha256='b'*64,native_shelf_core_sha256='c'*64)


class ReadbackProofTests(unittest.TestCase):
    def setUp(self):
        self.plan=retry_plan();self.original=OrdinaryReconnectRetryStore(Backend());self.receipt=self.original.reserve(self.plan)
        for before,after in (('prepared','enter_pending'),('enter_pending','enter_acknowledged'),('enter_acknowledged','enter_verified'),
                             ('enter_verified','position_pending'),('position_pending','position_acknowledged'),
                             ('position_acknowledged','position_verified'),('position_verified','restore_pending')):
            self.receipt=self.original.advance(self.receipt,before,after)
        self.proof=RestoreReadbackStore(Backend());self.bridge=RetryRecoveryRenewalStore(Backend())
    def binding(self):
        return dict(original_intent_sha256=hashlib.sha256(self.receipt.pending).hexdigest(),owner_sha256=self.plan['owner_sha256'],
                    native_grant_sha256=self.plan['grant_sha256'],renewal_bridge_sha256='0'*64,
                    source_sha256=self.plan['source_sha256'],catalog_sha256=self.plan['catalog_sha256'],
                    web_shelf_core_sha256=self.plan['web_shelf_core_sha256'],native_shelf_core_sha256=self.plan['native_shelf_core_sha256'])
    def test_confirmed_readback_seals_without_replay(self):
        self.proof.record(self.binding());self.original.close_after_restore_readback(self.receipt,self.proof,self.bridge)
        self.assertEqual(self.original.read()[0]['phase'],'restore_readback_confirmed');self.assertFalse(self.original.pending())
        with self.assertRaises(StoreError):self.original.close_after_restore_readback(self.receipt,self.proof,self.bridge)
    def test_foreign_or_missing_proof_cannot_close(self):
        with self.assertRaises(StoreError):self.original.close_after_restore_readback(self.receipt,self.proof,self.bridge)
        bad=self.binding();bad['source_sha256']='d'*64;self.proof.record(bad)
        with self.assertRaises(StoreError):self.original.close_after_restore_readback(self.receipt,self.proof,self.bridge)
        self.assertEqual(self.original.read()[0]['phase'],'restore_pending')
    def test_proof_is_single_use_and_checks_binding(self):
        bad=self.binding();bad['owner_sha256']='bad'
        with self.assertRaises(StoreError):self.proof.record(bad)
        self.proof.record(self.binding())
        with self.assertRaises(StoreError):self.proof.record(self.binding())
    def test_original_position_after_first_uncertain_send_can_close_without_writing(self):
        original=OrdinaryReconnectRetryStore(Backend());receipt=original.reserve(self.plan)
        receipt=original.advance(receipt,'prepared','enter_pending');item=self.binding()
        item['original_intent_sha256']=hashlib.sha256(receipt.pending).hexdigest()
        proof=RestoreReadbackStore(Backend());proof.record(item)
        original.close_after_restore_readback(receipt,proof,self.bridge)
        self.assertEqual(original.read()[0]['phase'],'baseline_readback_after_enter')
        self.assertEqual(original.read()[0]['posts'],1);self.assertFalse(original.pending())


if __name__=='__main__':unittest.main()
