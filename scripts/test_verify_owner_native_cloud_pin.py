from contextlib import redirect_stdout
import io
import json
import unittest
from unittest.mock import patch
from verify_eink_login import BASE
from verify_pin_preflight import fingerprint
import verify_owner_native_cloud_pin as task


class HostScopeTests(unittest.TestCase):
    def setUp(self):
        self.p=task.HostWriter();self.p.target='42';self.credentials={'vid':'123','accessToken':'synthetic'}
        self.p.grant=fingerprint(self.credentials)
    def test_exact_one_add_and_one_remove(self):
        seen=[]
        def request(_probe,stage,url,body=None,credentials=None,timeout=15):
            seen.append((stage,url,body));return {'succ':1}
        with patch('verify_eink_login.NativeProbe.request',new=request):
            self.p.send('add',self.credentials);self.p.send('remove',self.credentials)
            with self.assertRaises(ValueError):self.p.send('remove',self.credentials)
        self.assertEqual([(url,body) for _,url,body in seen],[(BASE+'/shelf/add',{'bookIds':['42']}),
                                                             (BASE+'/shelf/delete',{'bookIds':['42']})])
        self.assertEqual(self.p.attempts,2);self.assertEqual(len(self.p.receipts),2)
    def test_wrong_scope_and_replay_fail_closed(self):
        with self.assertRaises(ValueError):self.p.send('remove',self.credentials)
        with self.assertRaises(Exception):self.p.request('bad',BASE+'/shelf/top',{'bookIds':['42']},self.credentials)
        with self.assertRaises(ValueError):self.p.send('add',dict(self.credentials,vid='999'))
        with patch('verify_eink_login.NativeProbe.request',side_effect=TimeoutError):
            with self.assertRaises(TimeoutError):self.p.send('add',self.credentials)
            with self.assertRaises(ValueError):self.p.send('add',self.credentials)
        self.assertEqual(self.p.attempts,1)
    def test_offline_default_does_not_open_keychain(self):
        with patch.object(task,'PinTrialStore') as outer,patch.object(task,'NativeCloudPinTrialStore') as inner,\
             patch.object(task,'SessionStore') as session,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]),0)
        outer.assert_not_called();inner.assert_not_called();session.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['account_data_posts_attempted'],0)


if __name__=='__main__':unittest.main()
