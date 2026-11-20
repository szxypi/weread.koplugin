"""Bound CB identity and native time-only payload without account access."""
import copy,time,unittest
from cb_native_readtime_model import batch
from readtime_upload_model import batch as numeric_batch
from test_eink_renewal import credentials


class TestCBNativeTimeModel(unittest.TestCase):
    def test_preserves_all_numeric_protocol_fields_except_identity_signature(self):
        now=int(time.time());rows=[dict(start_time=now-2,duration=2,time_zone='+08:00',book_version=3)]
        args=(credentials(),rows,'synthetic-guest','synthetic-config',now,17,now*1000,18)
        target=batch(args[0],'CB_Synthetic',*args[1:],current_zone='+08:00')
        ordinary=numeric_batch(args[0],'1',*args[1:],current_zone='+08:00')
        self.assertEqual(target['books'][0]['bookId'],'CB_Synthetic')
        self.assertNotEqual(target['books'][0]['signature'],ordinary['books'][0]['signature'])
        reduced=copy.deepcopy(target);reduced['books'][0]['bookId']='1';reduced['books'][0]['signature']=ordinary['books'][0]['signature']
        self.assertEqual(reduced,ordinary)
        retained=batch(args[0],'CB_Synthetic',*args[1:],current_zone='+08:00',summary='合成摘要')
        self.assertEqual(retained['books'][0]['summary'],'合成摘要')
        self.assertEqual(retained['books'][0]['signature'],target['books'][0]['signature'])
    def test_rejects_invalid_id_and_future_or_mixed_rows(self):
        now=int(time.time());rows=[dict(start_time=now-2,duration=2,time_zone='+08:00',book_version=3)]
        for bad in ('1','CB_','CB_bad/','CB_'+('A'*65),None):
            with self.subTest(bad=bad),self.assertRaises(ValueError):
                batch(credentials(),bad,rows,'guest','config',now,1,now*1000,2,current_zone='+08:00')
        altered=copy.deepcopy(rows);altered[0]['start_time']=now
        with self.assertRaises(ValueError):batch(credentials(),'CB_Synthetic',altered,'guest','config',now,1,now*1000,2,current_zone='+08:00')
        for bad in ('', 'a\0b', '文'*513):
            with self.assertRaises(ValueError):batch(credentials(),'CB_Synthetic',rows,'guest','config',now,1,now*1000,2,current_zone='+08:00',summary=bad)


if __name__=='__main__':unittest.main()
