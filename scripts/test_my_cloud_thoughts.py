"""Independent synthetic own-thought model, read-only guard and report tests."""
from contextlib import redirect_stdout
from copy import deepcopy
import io
import json
import unittest
from personal_notes_position import unchanged,response_clock_matches
from run_my_cloud_marks_ui import native_budget
from unittest.mock import patch

from my_cloud_thoughts_model import page,complete,ThoughtsError
from verify_my_cloud_thoughts import ThoughtsProbe,main,BASE


def source(count=3,total=3):
    return dict(totalCount=total,hasMore=0,synckey=12345,reviews=[dict(reviewId=f'synthetic-{i}',review=dict(reviewId=f'synthetic-{i}',
        bookId='900001',userVid=900000,author=dict(userVid=900000,name='discard'),content=f'合成想法 {i}',abstract='引用文字',
        chapterUid=7,type=1,isPrivate=1,createTime=1000,private_extra='discard')) for i in range(count)])


class ThoughtsTests(unittest.TestCase):
    def test_crlf_quote_preserved_and_other_controls_refused(self):
        raw=source();raw['reviews'][0]['review']['abstract']='First\r\nSecond\tline'
        self.assertEqual(page(raw,'900001','900000')['reviews'][0]['abstract'],raw['reviews'][0]['review']['abstract'])
        for char in ('\x00','\x08','\x0b','\x0c','\x0e','\x1f','\x7f'):
            raw['reviews'][0]['review']['abstract']='Text'+char
            with self.subTest(char=ord(char)),self.assertRaises(ThoughtsError):page(raw,'900001','900000')

    def test_native_created_decimal_chapter_uid_is_canonicalized_only_for_that_field(self):
        raw=source();raw['reviews'][0]['review']['chapterUid']='7'
        self.assertEqual(complete(raw,'900001','900000',1000)['reviews'][0]['chapterUid'],7)
        self.assertEqual(raw['reviews'][0]['review']['chapterUid'],'7')
        for field,value in [('chapterUid','07'),('chapterUid','7.0'),('chapterUid','1e1'),('chapterUid',' 7'),('chapterUid','2147483648'),('chapterUid',True),('chapterIdx','7')]:
            bad=source();bad['reviews'][0]['review'][field]=value
            with self.subTest(field=field,value=value),self.assertRaises(ThoughtsError):complete(bad,'900001','900000',1000)

    def test_default_does_not_access_credentials_or_network(self):
        with patch('verify_my_cloud_thoughts.SessionStore') as web,patch('verify_my_cloud_thoughts.NativeSessionStore') as native,\
                patch('verify_my_cloud_thoughts.ThoughtsProbe') as probe,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main([]),0)
        web.assert_not_called();native.assert_not_called();probe.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_false_has_more_cannot_truncate_a_snapshot(self):
        self.assertTrue(page(source(1),'900001','900000')['has_more'])
        with self.assertRaises(ThoughtsError):complete(source(1),'900001','900000',1000)
        self.assertEqual(complete(source(0,0),'900001','900000',1000)['reviews'],[])

    def test_projection_strips_unrelated_fields_without_mutation(self):
        raw=source();before=deepcopy(raw);model=complete(raw,'900001','900000',1000)
        self.assertEqual(raw,before);self.assertEqual(model['reviews'][0]['content'],'合成想法 0')
        for field in ['author','userVid','private_extra','bookId']:self.assertNotIn(field,model['reviews'][0])
        self.assertNotIn('synckey',model)

    def test_scope_identity_and_bounded_fields(self):
        cases=[]
        for key,value in [('bookId','900002'),('userVid',900001),('content','bad\x00'),('content','x'*131073),('isPrivate',2),('createTime',True)]:
            raw=source();raw['reviews'][0]['review'][key]=value;cases.append(raw)
        raw=source();raw['reviews'][0]['review']['author']['userVid']=900001;cases.append(raw)
        raw=source();raw['reviews'][0]['review'].pop('userVid');raw['reviews'][0]['review'].pop('author');cases.append(raw)
        raw=source();raw['reviews'][0]['reviewId']='other';cases.append(raw)
        raw=source();raw['reviews'][1]=raw['reviews'][0];cases.append(raw)
        for key,value in [('reviews',{}),('totalCount',2),('hasMore','0'),('errcode',False)]:
            raw=source();raw[key]=value;cases.append(raw)
        for raw in cases:
            with self.subTest(keys=list(raw)),self.assertRaises((ThoughtsError,UnicodeError)):page(raw,'900001','900000')

    def test_only_the_validated_root_response_clock_can_change(self):
        before=dict(bookId='900001',timestamp=1000,book=dict(chapterUid=7,chapterOffset=12,progress=37,updateTime=500))
        after=deepcopy(before);after['timestamp']=1001
        self.assertTrue(unchanged(before,after,'900001'))
        for key,value in [('chapterOffset',13),('progress',38),('updateTime',501),('timestamp',1001)]:
            changed=deepcopy(after);changed['book'][key]=value
            self.assertFalse(unchanged(before,changed,'900001'))
        missing=deepcopy(after);del missing['timestamp'];self.assertFalse(unchanged(before,missing,'900001'))
        for value in [True,'1001',-1,float('inf')]:
            changed=deepcopy(after);changed['timestamp']=value
            with self.assertRaises(ValueError):unchanged(before,changed,'900001')

    def test_response_clock_is_the_request_time_not_a_reading_coordinate(self):
        self.assertTrue(response_clock_matches(dict(timestamp=1001),1000,1002))
        self.assertTrue(response_clock_matches(dict(timestamp=1794350001000),1794350000,1794350002))
        self.assertFalse(response_clock_matches(dict(timestamp=1001),2000,2002))
        self.assertFalse(response_clock_matches(dict(timestamp=True),1000,1002))
        self.assertTrue(response_clock_matches({},1000,1002))

    def test_real_ui_budget_covers_a_complete_prefix_chain(self):
        for total,count in [(0,1),(3,1),(20,1),(21,2),(45,3),(5000,9)]:self.assertEqual(native_budget(total),count)
        for invalid in [True,-1,5001]:
            with self.assertRaises(ValueError):native_budget(invalid)

    def test_request_guard_blocks_writes_other_books_variants_and_retry_budget(self):
        probe=ThoughtsProbe();probe.identity='900001'
        for stage,url,body in [('thoughts_20',BASE+'/review/list?bookId=900002&listType=11&listMode=0&mine=1&synckey=0&count=20',None),
                ('thoughts_20',BASE+'/review/list?bookId=900001&listType=1&listMode=0&mine=1&synckey=0&count=20',None),
                ('thoughts_20',BASE+'/review/list?bookId=900001&listType=11&listMode=0&mine=1&synckey=0&count=20',{}),
                ('write',BASE+'/review/add',{})]:
            with self.assertRaises(ValueError):probe.request(stage,url,body)
        self.assertEqual(probe.calls,0);probe.calls=13
        with self.assertRaises(ValueError):probe.request('shelf',BASE+'/shelf/sync')

    def test_page_probes_and_position_check_are_readonly(self):
        probe=ThoughtsProbe();probe.page_probe=True
        replies=[dict(books=[dict(bookId='900001')]),dict(books=[dict(bookId='900001',reviewCount=3)]),
                 dict(chapterUid=7,chapterOffset=12),source(),source(1),source(2),dict(chapterUid=7,chapterOffset=12)]
        with patch('verify_my_cloud_thoughts.NativeProbe.request',side_effect=replies) as requests,patch('verify_my_cloud_thoughts.time.sleep'):
            result=probe.prepare(dict(vid='900000'))
        self.assertEqual(requests.call_count,7);self.assertEqual(probe.calls,7)
        self.assertTrue(result['position_unchanged']);self.assertTrue(result['declared_count_matches'])
        self.assertTrue(all(p['has_more'] and p['prefix_matches'] for p in result['prefix_probes']))
        self.assertNotIn('合成想法',json.dumps(result));self.assertNotIn('900001',json.dumps(result))


if __name__=='__main__':unittest.main()
