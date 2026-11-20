"""Saved authorization renewal uses synthetic stores and no upstream calls."""
from contextlib import redirect_stdout
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from renew_saved_native_session import main
from secure_native_session import NativeSessionStore
from test_secure_native_session import Backend,credentials
from verify_eink_login import ProbeError


class SavedRenewalTests(unittest.TestCase):
    def test_offline_does_not_open_store_or_probe(self):
        with patch('renew_saved_native_session.NativeSessionStore') as native,patch('renew_saved_native_session.SessionStore') as web,\
                patch('renew_saved_native_session.RenewalProbe') as probe,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main([]),0)
        native.assert_not_called();web.assert_not_called();probe.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_once_verified_renewal_replaces_pending_and_redacts(self):
        backend=Backend();store=NativeSessionStore(backend)
        store.save(credentials(),'900000',verified=True)
        renewed=dict(credentials(),accessToken='private-new-access')
        report=dict(stages=[],renewal_attempts=0)
        def renew(previous):
            with self.assertRaisesRegex(Exception,'native_renewal_unconfirmed'):store.load('900000')
            self.assertEqual(previous['vid'],'900000')
            report['renewal_attempts']=1
            return renewed,dict(books=[dict(bookId='private-book')])
        probe=SimpleNamespace(report=report,renew=renew)
        with patch('renew_saved_native_session.NativeSessionStore',return_value=store),patch('renew_saved_native_session.SessionStore') as web,\
                patch('renew_saved_native_session.RenewalProbe',return_value=probe),redirect_stdout(io.StringIO()) as out:
            web.return_value.load.return_value=dict(vid='900000')
            self.assertEqual(main(['--saved-session','--renew']),0)
        self.assertEqual(store.load('900000')['accessToken'],'private-new-access')
        self.assertEqual(json.loads(out.getvalue())['authentication_posts_attempted'],1)
        for private in ('private-new-access','private-book','900000'):self.assertNotIn(private,out.getvalue())

    def test_unknown_receipt_blocks_new_process_and_never_retries(self):
        backend=Backend();store=NativeSessionStore(backend)
        store.save(credentials(),'900000',verified=True)
        report=dict(stages=[],renewal_attempts=0)
        def renew(_previous):report['renewal_attempts']=1;raise ProbeError('renewal: request timed out')
        with patch('renew_saved_native_session.NativeSessionStore',return_value=store),patch('renew_saved_native_session.SessionStore') as web,\
                patch('renew_saved_native_session.RenewalProbe',return_value=SimpleNamespace(report=report,renew=renew)),redirect_stdout(io.StringIO()):
            web.return_value.load.return_value=dict(vid='900000')
            self.assertEqual(main(['--saved-session','--renew']),1)
        with self.assertRaisesRegex(Exception,'native_renewal_unconfirmed'):NativeSessionStore(backend).load('900000')

    def test_failed_expiry_child_cannot_start_authentication_or_leak_output(self):
        store=NativeSessionStore(Backend());store.save(credentials(),'900000',verified=True)
        with patch('renew_saved_native_session.NativeSessionStore',return_value=store),patch('renew_saved_native_session.SessionStore') as web,\
                patch('renew_saved_native_session.RenewalProbe') as probe,\
                patch('renew_saved_native_session.subprocess.run',return_value=SimpleNamespace(returncode=1,stdout=b'private-output')),redirect_stdout(io.StringIO()) as out:
            web.return_value.load.return_value=dict(vid='900000')
            self.assertEqual(main(['--saved-session','--renew','--lua-expiry-command','synthetic']),1)
        probe.assert_not_called()
        self.assertEqual(store.load('900000'),credentials())
        self.assertNotIn('private-output',out.getvalue())


if __name__=='__main__':unittest.main()
