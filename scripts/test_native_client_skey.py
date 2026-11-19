"""Renewal capture remains private and cannot send account-data writes."""
from contextlib import redirect_stdout
import io
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

from secure_native_session import NativeSessionStore
from test_cloud_group_trial import shelf
from test_secure_native_session import Backend, credentials
from verify_eink_renewal import RenewalProbe
from verify_native_client_skey import CaptureProbe, execute, main


class Probe:
    def __init__(self,key='synthetic-secret',fail=False):
        self.client_key=key;self.report={'renewal_attempts':0};self.fail=fail
    def renew(self,previous):
        self.report['renewal_attempts']+=1
        if self.fail:raise OSError('synthetic loss')
        return dict(previous,accessToken='synthetic-new-access'),{'books':[]}


class Client:
    def __init__(self,error=False):self.calls=0;self.error=error
    def read(self,owner,key):
        assert owner=='900000' and key=='synthetic-secret'
        self.calls+=1
        if self.error:raise HTTPError('https://example.invalid',401,'',{},None)
        return shelf(True)


class Native:
    def __init__(self):self.calls=0
    def request(self,stage,url,credentials=None):
        assert stage=='shelf' and credentials['accessToken']=='synthetic-new-access'
        self.calls+=1;return shelf(True)


class NativeSkeyTest(unittest.TestCase):
    def setup_store(self):
        store=NativeSessionStore(Backend());store.save(credentials(),'900000',verified=True)
        return store

    def test_verified_and_rejected_keys_keep_renewal_and_never_leak(self):
        for rejected in (False,True):
            store=self.setup_store();probe=Probe();client=Client(rejected);native=Native()
            result=execute(store,'900000',store.load('900000'),probe,client,native)
            self.assertEqual(result['result'],'CLIENT_KEY_REJECTED' if rejected else 'CLIENT_KEY_READ_VERIFIED')
            self.assertEqual(result['authentication_posts'],1);self.assertEqual(result['account_data_posts'],0)
            self.assertEqual(client.calls,1);self.assertEqual(native.calls,1);self.assertIsNone(probe.client_key)
            self.assertEqual(store.load('900000')['accessToken'],'synthetic-new-access')
            self.assertNotIn('synthetic-secret',repr(result))

    def test_absent_key_does_not_attempt_client_read(self):
        store=self.setup_store();probe=Probe(None);client=Client();native=Native()
        result=execute(store,'900000',store.load('900000'),probe,client,native)
        self.assertEqual(result['result'],'CLIENT_KEY_ABSENT');self.assertEqual(client.calls,0);self.assertEqual(native.calls,0)

    def test_lost_renewal_keeps_pending_intent(self):
        store=self.setup_store();probe=Probe(fail=True);client=Client();native=Native()
        result=execute(store,'900000',store.load('900000'),probe,client,native)
        self.assertEqual(result['result'],'RENEWAL_UNVERIFIED');self.assertEqual(result['authentication_posts'],1)
        with self.assertRaisesRegex(Exception,'native_renewal_unconfirmed'):store.load('900000')
        self.assertEqual(client.calls,0)

    def test_only_valid_renewal_key_is_captured(self):
        probe=CaptureProbe()
        for stage,key,expected in (('other','synthetic-secret',None),('renewal','bad\nkey',None),
                                   ('renewal','',''),('renewal','synthetic-secret','synthetic-secret')):
            probe.client_key=None
            with patch.object(RenewalProbe,'request',return_value={'skey':key}):probe.request(stage,'https://example.invalid')
            self.assertEqual(probe.client_key,expected or None)

    def test_default_does_not_open_store_or_network(self):
        with patch('verify_native_client_skey.SessionStore') as session,patch('verify_native_client_skey.CaptureProbe') as probe,redirect_stdout(io.StringIO()):
            self.assertEqual(main([]),0)
        session.assert_not_called();probe.assert_not_called()


if __name__=='__main__':unittest.main()
