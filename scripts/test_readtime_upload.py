"""Independent signature vectors, time-only DTOs and strict interval contracts."""
from copy import deepcopy
import unittest
from readtime_upload_model import batch,confirmed,guest_token,hours,sign,validate_rows,zone
from selection_trial_mock import credentials

NOW=1700007200


def rows():return [dict(start_time=1700002799,duration=2,time_zone='+08:00',book_version=7)]


def payload():return batch(credentials(),'900001',rows(),'5ecdcfd7f','fixture-config',NOW,123,NOW*1000+123,456,current_zone='+00:00')


class ReadingTimeTests(unittest.TestCase):
    def test_reference_bytewise_vectors_include_utf8_and_empty_parts(self):
        # Independently executed MiuRead c1893562 readtime_protocol.lua.
        for parts,wanted in [(['5ecdcfd7f','123','1700000000','fixture_中文_😀'],'1c7559efd27f4b162851e86f057000466ba406d7005f14a0323f4027b48a792c'),
                (['a','b','c',''],'cc40c3dd32695af0481d8cfdd4409bc5870387c01aeacfbaaaa215b4c0636529'),
                (['0','999','4102444800','device_id_123'],'714b65712962735b3fce784d35460e7688cf34fc4684a029894b5673e6fb7502')]:
            self.assertEqual(sign(parts),wanted);self.assertEqual(sign(parts[::-1]),wanted)

    def test_complete_native_dto_matches_independent_reference(self):
        value=payload();book=value['books'][0]
        self.assertEqual(book['signature'],'de30ed1ad8d1c42bed906eb950814124be85a326fa587a6ee620724ae5b30c07')
        self.assertEqual(value['signature'],'e66ff5c23bb86ece21ca4bedc74c92424dc0cd20ec9eb541c22a6c610eec0cb0')
        self.assertEqual(set(value),{'books','timestamp','random','signature'})
        self.assertEqual(set(book),{'bookId','bookVersion','appId','deviceId','installId','summary','progress','currentProgress','autoTime','isLecture','isResendReadingInfo','lectureTime','lectureTextTime','novalTime','ttsTime','finish','risk','readingTime','recordCreateTimeZone','timestamp','random','hours','signature'})
        self.assertIs(book['finish'],False);self.assertEqual(book['isResendReadingInfo'],1);self.assertEqual(book['readingTime'],2)
        for name in ('chapterUid','chapterIdx','chapterOffset','isFinished','voiceType','novelTime','recordCreateTimeZone'):
            self.assertNotIn(name,value)
        for name in ('chapterUid','chapterIdx','chapterOffset','voiceType','novelTime'):self.assertNotIn(name,book)

    def test_hour_boundary_preserves_total_and_original_zone(self):
        value=hours(rows());self.assertEqual(value,[dict(startOfHour=1699999200,timeZone='+08:00',readingTime=1,ttsTime=0),dict(startOfHour=1700002800,timeZone='+08:00',readingTime=1,ttsTime=0)])
        self.assertEqual(sum(v['readingTime'] for v in value),2)

    def test_repeated_distinct_intervals_merge_without_resigning_inputs(self):
        r=[dict(rows()[0],start_time=1700000000),dict(rows()[0],start_time=1700000003)];before=deepcopy(r)
        self.assertEqual(validate_rows(r,'900001',NOW),4);self.assertEqual(hours(r)[0]['readingTime'],4);self.assertEqual(r,before)

    def test_overlap_future_and_bad_timestamp_are_rejected(self):
        for change in ({'duration':True},{'duration':0},{'duration':61},{'start_time':NOW},{'start_time':'1700000000'},{'book_version':True},{'book_version':0},{'book_version':2147483648}):
            with self.subTest(change=change),self.assertRaises(ValueError):validate_rows([dict(rows()[0],**change)],'900001',NOW)
        with self.assertRaises(ValueError):validate_rows(rows()*2,'900001',NOW)
        with self.assertRaises(ValueError):validate_rows([dict(rows()[0],extra='unexpected')],'900001',NOW)

    def test_mixed_versions_and_more_than_batch_limit_are_rejected(self):
        r=rows()+[dict(rows()[0],start_time=1700002801,book_version=8)]
        with self.assertRaises(ValueError):validate_rows(r,'900001',NOW)
        r=[dict(rows()[0],start_time=1700000000+i*60,duration=60) for i in range(11)]
        with self.assertRaises(ValueError):validate_rows(r,'900001',NOW)
        with self.assertRaises(ValueError):validate_rows(r*10,'900001',NOW)

    def test_unknown_tokens_and_envelope_clock_fail_closed(self):
        for guest,token,now,random,stamp,outer in [('', 'config',NOW,1,NOW*1000,2),('guest','',NOW,1,NOW*1000,2),('guest','config',NOW,True,NOW*1000,2),('guest','config',NOW,1,NOW*1000+2000,2),('guest','config',NOW,1,NOW*1000,1000)]:
            with self.assertRaises(ValueError):batch(credentials(),'900001',rows(),guest,token,now,random,stamp,outer,current_zone='+00:00')

    def test_zone_has_valid_bounds(self):
        for value in ('+00:00','-03:30','+14:00','-12:00'):self.assertEqual(zone(value),value)
        for value in ('+14:01','+15:00','+08:60','08:00',None):
            with self.assertRaises(ValueError):zone(value)

    def test_feature_default_is_not_an_authentication_fallback(self):
        self.assertEqual(guest_token(dict(feature={})),('5ecdcfd7f','client_default'))
        self.assertEqual(guest_token(dict(feature={'guest_token':'fixture-token'})),('fixture-token','remote'))
        for value in ({},dict(feature=[]),dict(feature={'guest_token':False}),dict(feature={'guest_token':3})):
            with self.assertRaises(ValueError):guest_token(value)

    def test_receipt_does_not_coerce_success(self):
        self.assertTrue(confirmed(dict(succ=1)));self.assertTrue(confirmed(dict(succ=True)))
        for value in ({},dict(succ='1'),dict(succ=1.0),dict(succ=0),dict(success=True),dict(succ=1,errcode=-1),dict(succ=1,errCode=False),None):self.assertFalse(confirmed(value))


if __name__=='__main__':unittest.main()
