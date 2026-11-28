import unittest
from unittest.mock import patch

from verify_eink_login import BASE
from verify_pin_preflight import fingerprint
from verify_pin_trial import Writer


class WriterTests(unittest.TestCase):
    def setUp(self):
        self.writer=Writer();self.writer.target='42';self.credentials={'vid':'123','accessToken':'synthetic'}
        self.writer.grant=fingerprint(self.credentials)
    def test_exact_single_use_requests(self):
        seen=[]
        def send(_probe,stage,url,body=None,credentials=None,timeout=15):
            seen.append((stage,url,body));return {'succ':1}
        with patch('verify_eink_login.NativeProbe.request',new=send):
            for name in ('add','pin','unpin','remove'):self.writer.send(name,self.credentials)
            with self.assertRaises(ValueError):self.writer.send('add',self.credentials)
        self.assertEqual([(url,body) for _,url,body in seen],[
            (BASE+'/shelf/add',{'bookIds':['42']}),
            (BASE+'/shelf/top',{'albumIds':[],'archiveIds':[],'bookIds':['42'],'isDel':0}),
            (BASE+'/shelf/top',{'albumIds':[],'archiveIds':[],'bookIds':['42'],'isDel':1}),
            (BASE+'/shelf/delete',{'bookIds':['42']})])
        self.assertEqual(self.writer.writes_attempted,4)
        self.assertEqual([row['stage'] for row in self.writer.receipts],['add','pin','unpin','remove'])
        self.assertTrue(all(row['known_fields']==['succ'] and row['other_fields_count']==0 for row in self.writer.receipts))
    def test_reject_unpermitted_wrong_order_and_changed_grant(self):
        with self.assertRaises(Exception):self.writer.request('pin_trial_add',BASE+'/shelf/add',{'bookIds':['42']},self.credentials)
        with self.assertRaises(ValueError):self.writer.send('pin',self.credentials)
        with self.assertRaises(ValueError):self.writer.send('add',dict(self.credentials,vid='999'))
        self.assertEqual(self.writer.writes_attempted,0)
    def test_failed_dispatch_is_never_replayed(self):
        with patch('verify_eink_login.NativeProbe.request',side_effect=TimeoutError):
            with self.assertRaises(TimeoutError):self.writer.send('add',self.credentials)
            with self.assertRaises(ValueError):self.writer.send('add',self.credentials)
        self.assertEqual(self.writer.writes_attempted,1);self.assertIsNone(self.writer.permit)


if __name__=='__main__':unittest.main()
