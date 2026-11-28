import contextlib
import io
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import verify_ordinary_reconnect_preview as subject


class PreviewTest(unittest.TestCase):
    def setUp(self):
        self.web=SimpleNamespace(book_id='900001',chapter='11',vid='900000',catalog={},
            plan={'baseline':{'chapter_idx':2,'chapter_offset':45}},shards={'e_0':'a','e_1':'b','e_3':'c'})
        self.saved={'cookies':{'wr_vid':'900000','wr_skey':'synthetic'}}
        self.chapter={'chapterUid':11,'chapterIdx':2,'wordCount':99}
        self.patches=[patch.object(subject,'normalize_chapter_infos',return_value=({},[self.chapter])),
                      patch.object(subject,'decode_content_shards',return_value='<html><body><p>synthetic</p></body></html>'),
                      patch.object(subject,'FilteredSource',return_value=object()),
                      patch.object(subject,'source_summary',return_value='synthetic')]
        for p in self.patches:p.start();self.addCleanup(p.stop)

    def test_payload_is_always_disarmed_and_bound(self):
        value,_=subject.build_payload(self.web,self.saved)
        self.assertEqual(value['book'],'900001');self.assertEqual(value['chapter'],'11')
        self.assertFalse(value['armed']);self.assertTrue(value['ordinary']);self.assertTrue(value['reconnect_discover'])
        self.assertEqual(value['first_offset'],45);self.assertIsNot(value['cookies'],self.saved['cookies'])

    def test_rejects_personal_book_and_bad_catalog(self):
        for book in ('CB_other','0','-2','1'*21):
            self.web.book_id=book
            with self.assertRaisesRegex(ValueError,'ordinary_reconnect/book'):subject.build_payload(self.web,self.saved)
        self.web.book_id='900001';self.chapter['chapterIdx']=3
        with self.assertRaisesRegex(ValueError,'ordinary_reconnect/catalog'):subject.build_payload(self.web,self.saved)
        self.chapter['chapterIdx']=2;self.chapter['wordCount']=0
        with self.assertRaisesRegex(ValueError,'ordinary_reconnect/catalog'):subject.build_payload(self.web,self.saved)

    def test_rejects_ambiguous_source(self):
        with patch.object(subject,'source_summary',return_value=None):
            with self.assertRaisesRegex(ValueError,'ordinary_reconnect/baseline'):subject.build_payload(self.web,self.saved)

    def test_default_offline_and_no_apply_option(self):
        with contextlib.redirect_stdout(io.StringIO()) as out:self.assertEqual(subject.main([]),0)
        self.assertIn('OFFLINE_ONLY',out.getvalue())
        with contextlib.redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):subject.main(['--apply'])


if __name__=='__main__':unittest.main()
