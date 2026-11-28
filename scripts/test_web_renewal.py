"""No real Keychain, subprocess or network; Web receipt bridge and default guards."""
import contextlib
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
from secure_weread_session import SessionStore
from test_secure_weread_session import Backend,probe
from verify_web_renewal import anonymous_account,native_renew,main

class WebRenewalTests(unittest.TestCase):
    def fixture(self):
        backend=Backend();store=SessionStore(backend);owner=probe();store.save(owner)
        owner.verify_account=lambda:None
        return store,owner,store.load()
    def result(self,saved,**changes):
        value={'ok':True,'posts':1,'verification_reads':3,'book_count':2,
               'candidate':{'cookies':dict(saved['cookies'],wr_skey='XXXrenewed-native'),'wr_ticket':'new-ticket','wr_wrpa':''}}
        value.update(changes)
        return SimpleNamespace(returncode=0,stdout=b'fixed startup\nWEREAD_WEB_AUTH_PRIVATE='+json.dumps(value).encode()+b'\n',stderr=b'')
    def test_default_does_not_open_keychain_or_network(self):
        with patch('verify_web_renewal.SessionStore',side_effect=AssertionError('Keychain')),patch('verify_web_renewal.MPProbe',side_effect=AssertionError('network')),contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main([]),0)
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')
    def test_anonymous_control_sends_no_credentials_and_follows_no_redirect(self):
        class Opener:
            def open(self,request,**_kwargs):
                self.request=request;value=io.BytesIO(b'{"vid":123}');value.status=200;return value
        opener=Opener();result=anonymous_account('123',opener)
        self.assertTrue(result['returns_requested_profile']);self.assertIsNone(opener.request.get_header('Cookie'))
        self.assertIsNone(opener.request.get_header('Authorization'));self.assertEqual(result['redirects_followed'],0)
    def test_anonymous_401_and_redirect_are_reported_without_locations(self):
        class Opener:
            def open(self,*_args,**_kwargs):raise HTTPError('https://weread.qq.com/',302,'private detail',{'Location':'private target'},None)
        result=anonymous_account('123',Opener());self.assertEqual(result['status'],302);self.assertFalse(result['returns_requested_profile']);self.assertNotIn('private',json.dumps(result))
    def test_native_intent_precedes_process_and_verified_receipt_commits(self):
        store,owner,saved=self.fixture();report={}
        def run(command,**options):
            self.assertTrue(store.load()['web']['renewal_pending'])
            self.assertEqual(command,['native-probe']);self.assertTrue(options['capture_output'])
            self.assertEqual(json.loads(options['input'])['cookies'],saved['cookies'])
            return self.result(saved)
        with patch('verify_web_renewal.subprocess.run',side_effect=run):
            committed,result=native_renew(store,saved,owner,['native-probe'],report)
        self.assertTrue(result['native_receipt_verified']);self.assertFalse(committed['web']['renewal_pending'])
        self.assertEqual(store.load()['cookies']['wr_skey'],'XXXrenewed-native')
    def test_lost_pipe_keeps_unknown_intent_without_replay(self):
        store,owner,saved=self.fixture();report={}
        with patch('verify_web_renewal.subprocess.run',side_effect=TimeoutError()) as process:
            with self.assertRaises(TimeoutError):native_renew(store,saved,owner,['native-probe'],report)
            with self.assertRaises(Exception):native_renew(store,saved,owner,['native-probe'],report)
        self.assertEqual(process.call_count,1);self.assertTrue(store.load()['web']['renewal_pending'])
        self.assertTrue(report['native_dispatch_attempted']);self.assertIsNone(report['native_maintenance_posts'])
    def test_foreign_receipt_cannot_replace_saved_owner(self):
        store,owner,saved=self.fixture();value=self.result(saved)
        raw=json.loads(value.stdout.split(b'WEREAD_WEB_AUTH_PRIVATE=')[1]);raw['candidate']['cookies']['wr_vid']='999'
        value.stdout=b'\nWEREAD_WEB_AUTH_PRIVATE='+json.dumps(raw).encode()
        with patch('verify_web_renewal.subprocess.run',return_value=value):
            with self.assertRaises(ValueError):native_renew(store,saved,owner,['native-probe'],{})
        self.assertEqual(store.load()['cookies'],saved['cookies']);self.assertTrue(store.load()['web']['renewal_pending'])
    def test_failed_native_exit_is_not_marked_native_verified(self):
        store,owner,saved=self.fixture();value=self.result(saved);value.returncode=1
        with patch('verify_web_renewal.subprocess.run',return_value=value):
            committed,result=native_renew(store,saved,owner,['native-probe'],{})
        self.assertFalse(result['native_receipt_verified']);self.assertFalse(committed['web']['renewal_pending'])
    def test_duplicate_frame_does_not_commit(self):
        store,owner,saved=self.fixture();value=self.result(saved);value.stdout+=value.stdout
        with patch('verify_web_renewal.subprocess.run',return_value=value):
            with self.assertRaises(ValueError):native_renew(store,saved,owner,['native-probe'],{})
        self.assertTrue(store.load()['web']['renewal_pending'])

if __name__=='__main__':unittest.main()
