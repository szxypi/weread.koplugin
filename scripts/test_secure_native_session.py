"""Synthetic native storage tests; no real Keychain, credentials or network."""
from contextlib import redirect_stdout
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from secure_native_session import NativeSessionStore,RenewalReceipt,project_lock
from secure_weread_session import StoreError
from verify_native_session import main


class Backend:
    def __init__(self):self.data=None
    def save(self,data):self.data=data
    def load(self):return self.data
    def delete(self):present=self.data is not None;self.data=None;return present


def credentials():
    return dict(vid='900000',accessToken='synthetic-native-access',refreshToken='synthetic-native-refresh',deviceId='eink334691225'+'1'*19)


class NativeStorageTests(unittest.TestCase):
    def test_verified_roundtrip_and_project_only_cleanup(self):
        backend=Backend();store=NativeSessionStore(backend)
        store.save(credentials(),'900000',verified=True)
        self.assertEqual(store.load('900000'),credentials())
        self.assertTrue(store.delete());self.assertFalse(store.delete())

    def test_wrong_owner_unverified_and_malformed_are_not_saved(self):
        backend=Backend();store=NativeSessionStore(backend)
        with self.assertRaises(StoreError):store.save(credentials(),'900000')
        with self.assertRaises(StoreError):store.save(credentials(),'900001',verified=True)
        value=credentials();value['accessToken']='bad\nheader'
        with self.assertRaises(StoreError):store.save(value,'900000',verified=True)
        self.assertIsNone(backend.data)

    def test_corruption_foreign_scope_and_readback_failure(self):
        backend=Backend();store=NativeSessionStore(backend)
        store.save(credentials(),'900000',verified=True)
        value=json.loads(backend.data);value['scope']='other-project';backend.data=json.dumps(value).encode()
        with self.assertRaises(StoreError):store.load('900000')
        backend.load=lambda:b'wrong'
        with self.assertRaisesRegex(StoreError,'native_keychain_readback_mismatch'):store.save(credentials(),'900000',verified=True)

    def test_default_is_offline_and_does_not_open_keychain(self):
        with patch('verify_native_session.SessionStore') as web,patch('verify_native_session.NativeSessionStore') as native,\
            patch('verify_native_session.NativeProbe') as probe,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main([]),0)
        web.assert_not_called();native.assert_not_called();probe.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_pending_receipt_survives_new_instance_and_never_replays(self):
        backend=Backend();store=NativeSessionStore(backend)
        store.save(credentials(),'900000',verified=True)
        receipt,previous=store.begin_renewal('900000',credentials())
        self.assertEqual(previous,credentials())
        self.assertNotIn(previous['accessToken'],repr(receipt))
        reopened=NativeSessionStore(backend)
        for method in (reopened.load,reopened.begin_renewal):
            with self.assertRaisesRegex(StoreError,'native_renewal_unconfirmed'):method('900000')
        renewed=dict(credentials(),accessToken='synthetic-new-access')
        store.finish_renewal(receipt,renewed,verified=True)
        self.assertEqual(reopened.load('900000'),renewed)
        with self.assertRaisesRegex(StoreError,'native_renewal_replaced'):store.finish_renewal(receipt,renewed,verified=True)

    def test_replacement_owner_and_unverified_finish_cannot_overwrite(self):
        backend=Backend();store=NativeSessionStore(backend)
        store.save(credentials(),'900000',verified=True)
        receipt,_=store.begin_renewal('900000')
        with self.assertRaises(StoreError):store.finish_renewal(receipt,credentials())
        with self.assertRaises(StoreError):store.finish_renewal(receipt,dict(credentials(),vid='900001'),verified=True)
        replacement=dict(credentials(),accessToken='synthetic-replacement')
        store.save(replacement,'900000',verified=True)
        with self.assertRaisesRegex(StoreError,'native_renewal_replaced'):store.finish_renewal(receipt,credentials(),verified=True)
        self.assertEqual(store.load('900000'),replacement)
        with self.assertRaisesRegex(StoreError,'native_renewal_replaced'):store.begin_renewal('900000',credentials())
        with self.assertRaisesRegex(StoreError,'native_renewal_replaced'):
            store.finish_renewal(RenewalReceipt('900000',backend.data),credentials(),verified=True)

    def test_only_proved_pre_dispatch_failure_can_release_pending(self):
        backend=Backend();store=NativeSessionStore(backend)
        store.save(credentials(),'900000',verified=True)
        receipt,_=store.begin_renewal('900000')
        with self.assertRaises(StoreError):store.release_renewal(receipt)
        store.release_renewal(receipt,not_dispatched=True)
        self.assertEqual(store.load('900000'),credentials())

    def test_lock_is_exclusive_and_contains_no_data(self):
        with tempfile.TemporaryDirectory() as root:
            path=Path(root)/'empty.lock'
            with project_lock(path):
                with self.assertRaisesRegex(StoreError,'native_session_busy'):
                    with project_lock(path):pass
            self.assertEqual(path.read_bytes(),b'')


if __name__=='__main__':unittest.main()
