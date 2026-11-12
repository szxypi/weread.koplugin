"""Native TXT reader fixture/proof boundary; no real accounts or credentials."""
from copy import deepcopy
import json
import time
import unittest
from native_reader_fixture import NativeReaderServer,BOOK_ID,GRANT,GUEST,COUNTS,chapter_txt
from native_txt_read_model import body
from txt_coordinates import PlainSource
from run_native_reader_position import decode,decode_diagnostic,FRAME,FLAGS


def wire():
    p=dict(book_id=BOOK_ID,chapter_uid='2',chapter_idx=2,chapter_offset=121,raw_percent=38,
           summary=PlainSource(chapter_txt(2)).excerpt(121)['text'])
    return body(GRANT,p,0,GUEST,int(time.time()),123,'+08:00')


def stage():
    return dict(result='PASS',phase='complete',failed_line=0,native_posts=3,web_posts=0,
                **{k:k!='pending_reopened' for k in FLAGS})


class ReaderPositionTests(unittest.TestCase):
    def setUp(self):self.server=NativeReaderServer()
    def tearDown(self):self.server.server_close()
    def test_only_three_zero_time_raw_source_writes_and_counts_preserved(self):
        for _i in range(3):
            self.assertEqual(self.server.route('POST','https://i.weread.qq.com/book/read',wire()),(200,{'succ':1}))
        with self.assertRaises(ValueError):self.server.route('POST','https://i.weread.qq.com/book/read',wire())
        self.assertEqual(self.server.native_posts,3);self.assertTrue(self.server.preserved_counts())
        self.assertEqual(self.server.snapshot()['book']['readingTime'],COUNTS['readingTime'])
    def test_wrong_units_summary_signature_versions_times_and_fields_rejected_before_write(self):
        for change in ({'summary':'guessed summary'},{'readingTime':False},{'hours':{}},{'bookVersion':700},
                       {'chapterIdx':1},{'chapterUid':'2'},{'bookId':'41'},{'signature':'0'*64},{'currentProgress':True},
                       {'timestamp':int(time.time())-31},{'random':True},{'extra':'private'}):
            value=wire();value.update(change)
            with self.subTest(change=change),self.assertRaises((ValueError,TypeError)):
                self.server.route('POST','https://i.weread.qq.com/book/read',value)
        self.assertEqual(self.server.native_posts,0)
    def test_noack_applies_once_without_inventing_receipt(self):
        self.server.route('POST','https://weread.qq.com/mock/native-control',{'mode':'noack'})
        self.assertEqual(self.server.route('POST','https://i.weread.qq.com/book/read',wire()),(200,{}))
        self.assertEqual(self.server.snapshot()['book']['chapterOffset'],121);self.assertTrue(self.server.preserved_counts())
    def test_web_write_and_other_native_writes_forbidden(self):
        for url in ('https://weread.qq.com/web/book/read','https://i.weread.qq.com/review/add',
                    'https://i.weread.qq.com/shelf/delete'):
            with self.assertRaises(ValueError):self.server.route('POST',url,wire())
    def test_explicit_zero_native_version_and_real_read_snapshot_shape(self):
        self.assertEqual(self.server.route('GET','https://i.weread.qq.com/book/info?bookId='+BOOK_ID,{})[1]['version'],0)
        self.assertEqual(self.server.route('GET','https://i.weread.qq.com/book/getProgress?bookId='+BOOK_ID,{})[1],self.server.snapshot())
        with self.assertRaises(ValueError):self.server.route('GET','https://i.weread.qq.com/book/getProgress?bookId=41',{})
    def test_synthetic_failure_diagnostic_has_no_private_or_unbounded_fields(self):
        v=dict(reason='source_position_changed',verified=True,state='error',numeric_book=True,source_basis='raw_txt_utf16')
        frame=lambda value:b'WEREAD_SYNTHETIC_SYNC_DIAGNOSTIC='+json.dumps(value).encode()+b'\n'
        self.assertEqual(decode_diagnostic(frame(v)),v)
        for change in ({'summary':'private'},{'reason':'raw private error'},{'verified':1},{'source_basis':'unknown'},{'state':'private'}):
            bad=dict(v,**change);self.assertIsNone(decode_diagnostic(frame(bad)))
        self.assertIsNone(decode_diagnostic(frame(v)*2));self.assertIsNone(decode_diagnostic(b'malformed'))
    def test_live_complete_proof_requires_native_and_no_web_route(self):
        value=stage();self.assertEqual(decode(FRAME+json.dumps(value).encode(),'live'),value)
        for key,bad in [('native_posts',2),('web_posts',1),('failed_line',True),('timed',False),('reader_from_shelf',False),('extra','private')]:
            other=deepcopy(value);other[key]=bad
            with self.subTest(key=key),self.assertRaises(ValueError):decode(FRAME+json.dumps(other).encode(),'live')
    def test_new_process_must_read_pending_without_any_dispatch(self):
        value=stage();value.update(native_posts=0,pending_reopened=True)
        decode(FRAME+json.dumps(value).encode(),'reopen')
        for change in ({'pending_reopened':False},{'native_posts':1}):
            other=dict(value,**change)
            with self.assertRaises(ValueError):decode(FRAME+json.dumps(other).encode(),'reopen')
        with self.assertRaises(ValueError):decode(FRAME+json.dumps(value).encode(),'unknown')


if __name__=='__main__':unittest.main()
