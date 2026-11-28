"""The alternate client authentication probe is fixed to one read-only GET."""
from contextlib import redirect_stdout
from copy import deepcopy
import io
import json
import unittest
from urllib.error import HTTPError
from unittest.mock import patch

from test_cloud_group_trial import shelf
from verify_cloud_group_auth import AndroidKeyShelf, WebKeyShelf, main
from verify_cloud_group_trial import FULL_SHELF


class Response:
    status=200
    def __init__(self,value):self.value=value
    def __enter__(self):return self
    def __exit__(self,*_args):return False
    def read(self,_limit):return json.dumps(self.value).encode()


class Opener:
    def __init__(self,value):self.value=value;self.calls=[]
    def open(self,request,timeout):
        self.calls.append((request,timeout));return Response(self.value)


class WebKeyShelfTest(unittest.TestCase):
    def test_only_fixed_get_and_no_credentials_in_url(self):
        opener=Opener(shelf(True));probe=WebKeyShelf(opener)
        self.assertEqual(probe.read('42','synthetic-key'),shelf(True))
        request,timeout=opener.calls[0]
        self.assertEqual(request.full_url,FULL_SHELF);self.assertEqual(request.get_method(),'GET')
        self.assertIsNone(request.data);self.assertNotIn('synthetic-key',request.full_url);self.assertEqual(timeout,15)

    def test_invalid_header_and_service_rejection_fail_closed(self):
        for owner,key in (('42\n','key'),('42','bad\nkey'),('x','key'),('42','')):
            with self.subTest(owner=owner,key=key),self.assertRaises(ValueError):WebKeyShelf(Opener({})).read(owner,key)
        for value in (-1,False,0.0):
            with self.subTest(code=value),self.assertRaises(ValueError):WebKeyShelf(Opener({'errcode':value})).read('42','synthetic-key')

    def test_android_profile_still_allows_only_the_fixed_shelf_read(self):
        opener=Opener(shelf(True));probe=AndroidKeyShelf(opener)
        self.assertEqual(probe.read('42','synthetic-key'),shelf(True))
        request,timeout=opener.calls[0]
        self.assertEqual((request.full_url,request.get_method(),request.data,timeout),(FULL_SHELF,'GET',None,15))
        self.assertEqual(request.get_header('User-agent'),'WeRead/7.0.0 WRBrand/huawei Dalvik/2.1.0')
        self.assertEqual(request.get_header('V'),'7.4.2.23')
        self.assertEqual(request.get_header('Skey'),'synthetic-key')
        self.assertNotIn('synthetic-key',request.full_url)
        self.assertIsNone(request.get_header('Cookie'));self.assertIsNone(request.get_header('Authorization'))
        for owner,key in (('42','bad\nkey'),('x','key'),('42','')):
            with self.assertRaises(ValueError):probe.read(owner,key)
        self.assertEqual(len(opener.calls),1)

    def test_default_never_opens_credentials_or_network(self):
        with patch('verify_cloud_group_auth.SessionStore') as session,patch('verify_cloud_group_auth.WebKeyShelf') as probe,redirect_stdout(io.StringIO()):
            self.assertEqual(main([]),0)
        session.assert_not_called();probe.assert_not_called()
    def test_android_profile_requires_saved_session(self):
        with redirect_stdout(io.StringIO()),self.assertRaises(SystemExit):main(['--android-profile'])

    def test_rotated_web_session_is_saved_before_rejected_client_read(self):
        class Store:
            value={'vid':'42','cookies':{'wr_skey':'old-key'}}
            def load(self):return deepcopy(self.value)
        class NativeStore:
            def load(self,_owner):return {'vid':'42','accessToken':'synthetic'}
        class Web:
            def __init__(self):self.vid=None
            def set_cookie(self,*_args):pass
            def verify_account(self):pass
            def close(self):pass
        class Native:
            def request(self,*_args,**_kwargs):return shelf(True)
        class Rejected:
            def read(self,owner,key):
                self.assert_values=(owner,key)
                assert self.assert_values==('42','new-key') and store.value['cookies']['wr_skey']=='new-key'
                raise HTTPError(FULL_SHELF,401,'rejected',{},None)
        store=Store()
        def save(session,saved,_web):
            assert session is store and saved['cookies']['wr_skey']=='old-key'
            session.value={'vid':'42','cookies':{'wr_skey':'new-key'}};return True
        out=io.StringIO()
        with patch('verify_cloud_group_auth.SessionStore',return_value=store), \
             patch('verify_cloud_group_auth.NativeSessionStore',NativeStore), \
             patch('verify_cloud_group_auth.WebFlagsProbe',Web),patch('verify_cloud_group_auth.NativeProbe',Native), \
             patch('verify_cloud_group_auth.AndroidKeyShelf',Rejected), \
             patch('verify_cloud_group_auth.save_refreshed_web_session',side_effect=save),redirect_stdout(out):
            self.assertEqual(main(['--saved-session','--android-profile']),1)
        result=json.loads(out.getvalue())
        self.assertEqual((result['phase'],result['http_status'],result['web_rotation_saved']),('client_shelf',401,True))
        self.assertEqual(result['account_data_posts'],0)


if __name__=='__main__':unittest.main()
