"""Synthetic native storage tests; no real Keychain, credentials or network."""
from contextlib import redirect_stdout
import io
import json
import unittest
from unittest.mock import patch

from secure_native_session import NativeSessionStore
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


if __name__=='__main__':unittest.main()
