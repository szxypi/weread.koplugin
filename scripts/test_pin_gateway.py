import json
import unittest
from verify_pin_gateway import KeyWeb,KEY_URL,obtain,validate
from secure_weread_session import ACCOUNT

KEY='wrk-xxxxxxxxxxxxxxxxxxxx'


class Backend:
    def __init__(self,initial=None):self.data=initial;self.saves=0
    def load(self):return self.data
    def save(self,data):self.saves+=1;self.data=data


class Web:
    def __init__(self):self.verifies=0;self.requests=0;self.fail_verify=None;self.response={'apikey':KEY}
    def verify_account(self):
        self.verifies+=1
        if self.verifies==self.fail_verify:raise ValueError('account')
    def request(self,stage,url):
        assert stage=='skill_key' and url==KEY_URL
        self.requests+=1;return self.response


def report():return {'key_request_attempted':False,'keychain_saved':False,'keychain_reused':False}


class KeyTests(unittest.TestCase):
    def test_create_save_before_second_account_check(self):
        web,backend,state=Web(),Backend(),report();web.fail_verify=2
        with self.assertRaises(ValueError):obtain(web,backend,'123',True,state)
        self.assertEqual(web.requests,1);self.assertTrue(state['keychain_saved'])
        self.assertEqual(validate(json.loads(backend.data),'123')['key'],KEY)

    def test_reuse_never_requests_or_overwrites(self):
        web,backend,state=Web(),Backend(),report();self.assertEqual(obtain(web,backend,'123',True,state),KEY)
        saved=backend.data;web2=Web();state=report()
        self.assertEqual(obtain(web2,backend,'123',True,state),KEY)
        self.assertEqual(web2.requests,0);self.assertEqual(backend.saves,1);self.assertEqual(backend.data,saved)
        self.assertTrue(state['keychain_reused'])

    def test_different_owner_not_overwritten(self):
        web,backend=Web(),Backend();obtain(web,backend,'123',True,report());saved=backend.data
        with self.assertRaises(ValueError):obtain(Web(),backend,'456',True,report())
        self.assertEqual(backend.data,saved);self.assertEqual(backend.saves,1)

    def test_no_creation_without_flag_or_verified_account(self):
        web,backend=Web(),Backend()
        with self.assertRaises(ValueError):obtain(web,backend,'123',False,report())
        web.fail_verify=1
        with self.assertRaises(ValueError):obtain(web,backend,'123',True,report())
        self.assertEqual(web.requests,0);self.assertIsNone(backend.data)

    def test_bad_response_does_not_save(self):
        for response in ({}, {'apikey':'other'}, {'apikey':KEY,'errcode':42}, {'apikey':KEY+'\n'}):
            with self.subTest(response_type=type(response).__name__):
                web,backend=Web(),Backend();web.response=response
                with self.assertRaises(ValueError):obtain(web,backend,'123',True,report())
                self.assertIsNone(backend.data);self.assertEqual(web.requests,1)

    def test_schema_rejects_extra_data(self):
        value=dict(schema=1,scope=ACCOUNT,owner='123',key=KEY,created_at='now',extra=True)
        with self.assertRaises(ValueError):validate(value,'123')

    def test_request_guard(self):
        web=KeyWeb();web.authenticated=True
        web.guard('skill_key',KEY_URL,None)
        for stage,url,body in (('skill_key',KEY_URL,{}),('skill_key',KEY_URL+'?x=1',None),('other',KEY_URL,None)):
            with self.assertRaises(Exception):web.guard(stage,url,body)
        web.close()


if __name__=='__main__':unittest.main()
