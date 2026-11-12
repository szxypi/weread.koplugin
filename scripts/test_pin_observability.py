"""Offline tests for read scope, unknown pins and sensitive response boundaries."""
from contextlib import redirect_stdout
import io
import json
import unittest
from unittest.mock import Mock,patch
import verify_pin_observability as task


def shelf():return dict(books=[dict(bookId='41',secret=0,finishReading=0),dict(bookId='42',secret=1,finishReading=1)])


class PinReadTests(unittest.TestCase):
    def test_default_never_opens_credentials_or_network(self):
        with patch.object(task,'SessionStore') as store,patch.object(task,'gateway') as call,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        store.assert_not_called();call.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')
    def test_missing_pin_is_unknown_and_explicit_false_is_observable(self):
        value=shelf();result,_rows=task.project(value);self.assertEqual(result,dict(books=2,pinned=dict(missing=2)))
        value['books'][0]['isTop']=False;value['books'][1]['isTop']=True
        result,rows=task.project(dict(data=value));self.assertEqual(result['pinned'],{'true':1,'false':1});self.assertEqual(rows['41']['pinned'],dict(value=False))
    def test_invalid_flags_are_not_treated_as_false(self):
        value=shelf();value['books'][0]['isTop']='0';result,_rows=task.project(value)
        self.assertEqual(result['pinned'],dict(invalid=1,missing=1))
    def test_malformed_rejected_or_deep_envelope_is_not_a_shelf(self):
        for value in ({'errcode':1,'books':[]},{'errCode':-1,'data':shelf()},{'books':{}},{'result':{'data':{'result':{'data':shelf()}}}}):
            with self.subTest(value=value),self.assertRaises(ValueError):task.unwrap(value)
    def test_native_scope_rejects_all_writes_and_unlisted_queries(self):
        probe=task.Reads()
        for url,body in ((task.BASE+'/book/secret',{}),(task.BASE+'/shelf/top',{}),(task.BASE+'/shelf/sync',{}),
                         (task.BASE+'/shelf/sync?synckey=1',None),(task.BASE+'/login',None)):
            with self.assertRaises(ValueError):probe.request('pin_shelf',url,body)
    def test_web_key_lookup_is_get_only_after_account_verified(self):
        probe=task.Web()
        with self.assertRaises(task.PreflightError):probe.guard('account',task.KEY_URL,None)
        probe.authenticated=True;probe.guard('account',task.KEY_URL,None)
        for url,body in ((task.KEY_URL,{}),(task.KEY_URL.replace('only_show=1','only_show=0'),None)):
            with self.assertRaises(task.PreflightError):probe.guard('account',url,body)
        probe.close()
    def test_gateway_is_one_read_api_with_no_web_cookie(self):
        response=Mock(status=200);response.read.return_value=json.dumps(dict(data=shelf())).encode()
        response.__enter__=Mock(return_value=response);response.__exit__=Mock(return_value=False);opener=Mock();opener.open.return_value=response
        self.assertEqual(task.gateway('wrk-'+'x'*24,opener),shelf())
        req=opener.open.call_args.args[0];self.assertEqual(req.full_url,task.GATEWAY)
        self.assertEqual(json.loads(req.data),dict(api_name='/shelf/sync',skill_version='1.0.5'))
        self.assertIsNone(req.get_header('Cookie'));self.assertEqual(opener.open.call_count,1)
    def test_gateway_rejects_invalid_keys_and_oversized_or_invalid_responses(self):
        opener=Mock()
        for key in ('',None,'invalid','wrk-'+'a\n'*10):
            with self.assertRaises(ValueError):task.gateway(key,opener)
        opener.open.assert_not_called()
        response=Mock(status=200);response.__enter__=Mock(return_value=response);response.__exit__=Mock(return_value=False);opener.open.return_value=response
        for data in (b'x'*(4*1024*1024+1),b'{}',b'invalid'):
            response.read.return_value=data
            with self.assertRaises(ValueError):task.gateway('wrk-'+'x'*24,opener)


if __name__=='__main__':unittest.main()
