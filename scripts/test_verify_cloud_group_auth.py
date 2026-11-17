"""The alternate client authentication probe is fixed to one read-only GET."""
from contextlib import redirect_stdout
import io
import json
import unittest
from unittest.mock import patch

from test_cloud_group_trial import shelf
from verify_cloud_group_auth import WebKeyShelf, main
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
        with self.assertRaises(ValueError):WebKeyShelf(Opener({'errcode':-1})).read('42','synthetic-key')

    def test_default_never_opens_credentials_or_network(self):
        with patch('verify_cloud_group_auth.SessionStore') as session,patch('verify_cloud_group_auth.WebKeyShelf') as probe,redirect_stdout(io.StringIO()):
            self.assertEqual(main([]),0)
        session.assert_not_called();probe.assert_not_called()


if __name__=='__main__':unittest.main()
