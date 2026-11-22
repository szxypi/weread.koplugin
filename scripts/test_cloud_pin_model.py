import copy
from contextlib import redirect_stdout
import io
import json
import unittest
from unittest.mock import patch
from cloud_pin_contract import make,request
from test_shelf_flag_change import source,point
from verify_cloud_pin_model import Probe,main,plans
from verify_eink_login import BASE


class CloudPinModelTests(unittest.TestCase):
    def test_missing_baseline_stays_unknown(self):
        value=source();plan=make(value,point(),'41',True)
        self.assertEqual(plan['metadata']['before'],'missing')
        self.assertEqual(plan['body'],dict(bookIds=['41'],albumIds=[],archiveIds=[],isDel=0))
        self.assertNotEqual(plan['metadata']['after_hash'],plan['metadata']['before_hash'])
        with self.assertRaises(ValueError):make(value,point(),'41',False)
    def test_unpin_accepts_false_or_missing_without_guesses(self):
        value=source();value['books'][0]['isTop']=1;plan=make(value,point(),'41',False)
        self.assertTrue(plan['metadata']['before']);self.assertEqual(plan['body']['isDel'],1)
        self.assertNotEqual(plan['metadata']['after_hash'],plan['metadata']['alternate_hash'])
        self.assertEqual(plans(source(),point(),'41')[1],plan['metadata'])
    def test_unrelated_invalid_flag_and_bad_target_rejected(self):
        value=copy.deepcopy(source());value['books'][1]['isTop']='1'
        with self.assertRaises(ValueError):make(value,point(),'41',True)
        for identity in ('0','CB_1','41/2'):
            with self.subTest(identity=identity),self.assertRaises(ValueError):request(identity,True)
    def test_scope_and_offline_default(self):
        p=Probe();p.target='41'
        for url,body in ((BASE+'/shelf/top',{}),(BASE+'/book/getProgress?bookId=42',None)):
            with self.assertRaises(ValueError):p.request('bad',url,body,credentials={})
        with patch('verify_cloud_pin_model.SessionStore') as session,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main([]),0)
        session.assert_not_called();self.assertEqual(json.loads(out.getvalue())['account_data_writes'],0)


if __name__=='__main__':unittest.main()
