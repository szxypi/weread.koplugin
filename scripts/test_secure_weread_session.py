"""Never accesses the real Keychain, browser, credentials or network."""
from contextlib import redirect_stdout
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from secure_weread_session import ACCOUNT, MAX_BYTES, SessionStore, StoreError, validate
from verify_web_source_progress import PreflightError, WebSourceProbe, main


class Backend:
    def __init__(self):
        self.data = None

    def save(self, data):
        self.data = data

    def load(self):
        return self.data

    def delete(self):
        present = self.data is not None
        self.data = None
        return present


def payload():
    return dict(schema=1, scope=ACCOUNT, created_at='2026-11-08T00:00:00+00:00', vid='88008800',
                cookies=dict(wr_vid='88008800', wr_skey='synthetic-token'))


def probe():
    value=WebSourceProbe()
    value.vid='88008800'
    value.set_cookie('wr_vid',value.vid)
    value.set_cookie('wr_skey','synthetic-token')
    value.authenticated=True
    return value


class SecureSessionTests(unittest.TestCase):
    def test_verified_account_save_readback_load_delete(self):
        backend=Backend();store=SessionStore(backend)
        store.save(probe())
        value=store.load()
        self.assertEqual(value['vid'],'88008800')
        self.assertEqual(value['cookies']['wr_skey'],'synthetic-token')
        self.assertTrue(store.delete())
        self.assertFalse(store.delete())
        with self.assertRaisesRegex(StoreError,'^saved_session_missing$'):
            store.load()

    def test_save_requires_verified_login_and_matching_account(self):
        backend=Backend();store=SessionStore(backend)
        value=probe();value.authenticated=False
        with self.assertRaises(StoreError):store.save(value)
        value.authenticated=True;value.vid='99009900'
        with self.assertRaises(StoreError):store.save(value)
        self.assertIsNone(backend.data)

    def test_wrong_project_schema_account_and_extra_fields_rejected(self):
        for changes in (dict(scope='other-goal'),dict(schema=2),dict(schema=True),dict(vid='99009900'),dict(token='secret')):
            value=payload();value.update(changes)
            with self.assertRaisesRegex(StoreError,'^session_invalid$'):validate(value)

    def test_only_bounded_cookie_whitelist_is_saved(self):
        for cookies in ({},dict(wr_vid='88008800',wr_skey='x',other='secret'),
                        dict(wr_vid='88008800',wr_skey='x'*4097),dict(wr_vid='88008800',wr_skey='x\ny')):
            value=payload();value['cookies']=cookies
            with self.assertRaises(StoreError):validate(value)

    def test_corruption_and_oversized_values_have_controlled_diagnostics(self):
        backend=Backend();store=SessionStore(backend)
        for data in (b'private-token',b'\xff',b'x'*(MAX_BYTES+1),b'{}'):
            backend.data=data
            with self.assertRaises(StoreError) as error:store.load()
            self.assertNotIn('private-token',str(error.exception))

    def test_readback_mismatch_does_not_claim_saved_credentials(self):
        backend=Backend();backend.load=lambda: b'wrong-readback' if backend.data is not None else None
        with self.assertRaisesRegex(StoreError,'^keychain_readback_mismatch$'):
            SessionStore(backend).save(probe())

    def test_read_failure_never_overwrites_an_existing_record(self):
        backend=Backend();backend.data=b'private-unreadable-record'
        with self.assertRaisesRegex(StoreError,'^session_invalid$'):SessionStore(backend).save(probe())
        self.assertEqual(backend.data,b'private-unreadable-record')

    def test_pending_marker_saved_and_unknown_renewal_cannot_replay(self):
        backend=Backend();store=SessionStore(backend);store.save(probe())
        pending=store.begin_renewal(store.load())
        self.assertTrue(store.load()['web']['renewal_pending'])
        self.assertEqual(store.load(),pending)
        with self.assertRaisesRegex(StoreError,'^renewal_unconfirmed$'):store.begin_renewal(pending)
        store.save(probe())
        self.assertTrue(store.load()['web']['renewal_pending'])

    def test_renewal_commits_headers_after_verified_same_account(self):
        backend=Backend();store=SessionStore(backend);store.save(probe())
        pending=store.begin_renewal(store.load())
        renewed=probe();renewed.set_cookie('wr_skey','synthetic-renewed-cookie')
        committed=store.finish_renewal(renewed,pending,{'wr_ticket':'synthetic-mp-ticket','wr_wrpa':'synthetic-mp-protection'})
        self.assertFalse(committed['web']['renewal_pending'])
        self.assertEqual(committed['cookies']['wr_skey'],'synthetic-renewed-cookie')
        store.save(renewed)
        self.assertEqual(store.load()['web']['headers']['wr_ticket'],'synthetic-mp-ticket')
        with self.assertRaisesRegex(StoreError,'^session_changed$'):store.finish_renewal(renewed,pending,{})

    def test_missing_renewal_header_retains_previous_same_owner_grant(self):
        store=SessionStore(Backend());store.save(probe())
        first=store.finish_renewal(probe(),store.begin_renewal(store.load()),{'wr_ticket':'synthetic-old-ticket','wr_wrpa':'synthetic-old-protection'})
        second=store.finish_renewal(probe(),store.begin_renewal(first),{'wr_ticket':'synthetic-new-ticket'})
        self.assertEqual(second['web']['headers'],{'wr_ticket':'synthetic-new-ticket','wr_wrpa':'synthetic-old-protection'})

    def test_verified_new_cookie_preserves_headers_but_replaces_pending_authority(self):
        store=SessionStore(Backend());store.save(probe())
        saved=store.finish_renewal(probe(),store.begin_renewal(store.load()),{'wr_ticket':'synthetic-old-ticket'})
        pending=store.begin_renewal(saved)
        current=probe();current.set_cookie('wr_skey','synthetic-new-authority')
        store.save(current);actual=store.load()
        self.assertFalse(actual['web']['renewal_pending'])
        self.assertEqual(actual['web']['headers']['wr_ticket'],'synthetic-old-ticket')
        with self.assertRaises(StoreError):store.finish_renewal(probe(),pending,{})

    def test_replaced_cookie_cannot_receive_old_renewal(self):
        backend=Backend();store=SessionStore(backend);store.save(probe())
        pending=store.begin_renewal(store.load())
        newer=probe();newer.set_cookie('wr_skey','synthetic-other-authority');store.save(newer)
        before=backend.data
        with self.assertRaisesRegex(StoreError,'^session_changed$'):store.finish_renewal(probe(),pending,{})
        self.assertEqual(backend.data,before)

    def test_unverified_or_other_owner_cannot_commit_headers(self):
        backend=Backend();store=SessionStore(backend);store.save(probe())
        pending=store.begin_renewal(store.load())
        bad=probe();bad.authenticated=False
        with self.assertRaises(StoreError):store.finish_renewal(bad,pending,{})
        bad=probe();bad.vid='99009900';bad.set_cookie('wr_vid',bad.vid)
        with self.assertRaises(StoreError):store.finish_renewal(bad,pending,{})
        self.assertTrue(store.load()['web']['renewal_pending'])

    def test_unsafe_header_or_marker_rejected(self):
        value=payload();value.update(schema=2,web=dict(revision=1,renewal_pending=False,headers={}))
        for headers in ({'unexpected':'private'},{'wr_ticket':'private\nheader'},{'wr_ticket':'x'*8193}):
            bad=json.loads(json.dumps(value));bad['web']['headers']=headers
            with self.assertRaisesRegex(StoreError,'^session_invalid$'):validate(bad)
        value['web']['revision']=True
        with self.assertRaises(StoreError):validate(value)

    def test_default_mode_never_instantiates_store(self):
        with patch('verify_web_source_progress.SessionStore') as store, redirect_stdout(io.StringIO()):
            self.assertEqual(main([]),0)
        store.assert_not_called()

    def test_clear_mode_is_project_scoped_and_does_not_network(self):
        backend=Backend();store=SessionStore(backend);store.save(probe())
        with patch('verify_web_source_progress.SessionStore',return_value=store), \
             patch.object(WebSourceProbe,'request',side_effect=AssertionError('network')),redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main(['--clear-saved-session']),0)
        self.assertTrue(json.loads(out.getvalue())['saved_session_removed'])

    def test_saved_session_is_reverified_before_any_source_read(self):
        backend=Backend();store=SessionStore(backend);store.save(probe())
        order=[]
        def verify(value):
            self.assertFalse(value.authenticated)
            self.assertEqual(value.vid,'88008800')
            self.assertIn('synthetic-token',[cookie.value for cookie in value.cookies])
            order.append('account');value.authenticated=True
        def inspect(value,_book):
            self.assertTrue(value.authenticated);order.append('source')
        with patch('verify_web_source_progress.SessionStore',return_value=store),patch.object(WebSourceProbe,'verify_account',verify), \
             patch.object(WebSourceProbe,'inspect',inspect),redirect_stdout(io.StringIO()):
            self.assertEqual(main(['--saved-session','--book-id','900001']),0)
        self.assertEqual(order,['account','source'])

    def test_successful_login_is_saved_even_when_source_inspection_fails(self):
        backend=Backend();store=SessionStore(backend)
        value=probe();value.authenticated=False
        def login(current,_show,_otp):current.authenticated=True
        with patch.dict('sys.modules',qrcode=SimpleNamespace()),patch('verify_web_source_progress.SessionStore',return_value=store), \
             patch('verify_web_source_progress.WebSourceProbe',return_value=value),patch.object(value,'login',side_effect=lambda show,otp: login(value,show,otp)), \
             patch.object(value,'inspect',side_effect=PreflightError('position_missing')),redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main(['--interactive','--save-session','--book-id','900001']),1)
        self.assertEqual(store.load()['cookies']['wr_skey'],'synthetic-token')
        self.assertEqual(list(value.cookies),[])
        self.assertTrue(json.loads(out.getvalue())['credentials_saved'])
        self.assertNotIn('synthetic-token',out.getvalue())

    def test_failed_saved_account_check_never_reaches_source_and_does_not_delete_store(self):
        backend=Backend();store=SessionStore(backend);store.save(probe());before=backend.data
        with patch('verify_web_source_progress.SessionStore',return_value=store), \
             patch.object(WebSourceProbe,'verify_account',side_effect=PreflightError('account_mismatch')), \
             patch.object(WebSourceProbe,'inspect') as inspect,redirect_stdout(io.StringIO()):
            self.assertEqual(main(['--saved-session','--book-id','900001']),1)
        inspect.assert_not_called()
        self.assertEqual(backend.data,before)


if __name__=='__main__':
    unittest.main()
