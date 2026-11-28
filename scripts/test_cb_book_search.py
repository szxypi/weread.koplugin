"""CB_ search inspection stays offline by default and limits every read."""
import contextlib
import io
import json
import unittest
from unittest.mock import patch
from urllib.parse import urlencode

import verify_cb_book_search as task


class CBBookSearchTests(unittest.TestCase):
    def test_default_never_loads_credentials_or_creates_probe(self):
        for args in ([],['--native-ui']):
            output=io.StringIO()
            with patch.object(task,'SessionStore',side_effect=AssertionError('credentials')):
                with patch.object(task,'SearchProbe',side_effect=AssertionError('network')):
                    with contextlib.redirect_stdout(output):self.assertEqual(task.main(args),0)
            self.assertEqual(json.loads(output.getvalue()),{'result':'OFFLINE_ONLY','account_data_posts':0,
                'authentication_posts':0,'search_gets':0})

    def test_search_requires_exact_book_chapter_and_keyword_and_never_repeats(self):
        probe=task.SearchProbe();probe.authenticated=True;probe.vid='900000';probe.book_id='CB_Synthetic1'
        probe.allowed={probe.book_id};probe.chapter='7';probe.keyword='合成查询'
        probe.search_url=task.BASE+'/web/book/search_v2?'+urlencode(dict(bookId=probe.book_id,chapterUid='7',
            keyword=probe.keyword,posBegin=0,posEnd=0,mode='scrollDown',count=50))
        try:
            for url,body in ((probe.search_url,{}),(probe.search_url+'&other=1',None),
                    (probe.search_url.replace('chapterUid=7','chapterUid=8'),None),
                    (probe.search_url.replace('CB_Synthetic1','CB_Other'),None)):
                with self.assertRaises(ValueError):probe.guard('search_long',url,body)
            probe.guard('search_long',probe.search_url,None)
            with self.assertRaisesRegex(ValueError,'search_repeated'):probe.guard('search_long',probe.search_url,None)
            with self.assertRaises(task.PreflightError):probe.guard('search_progress_after',task.BASE+'/web/book/read',{})
            with self.assertRaises(ValueError):probe.guard('ui_e_0',task.BASE+'/web/book/read',{})
        finally:probe.close()

    def test_source_query_is_unique_and_carries_original_offsets(self):
        raw='<html><body><p>这里是一段足够长的合成中文测试文字，后面是其他内容。</p></body></html>'
        term,offset=task.query_text(raw)
        self.assertIsNotNone(term);self.assertEqual(raw.count(term),1)
        self.assertEqual(raw.encode('utf-16-le')[offset[0]*2:offset[1]*2].decode('utf-16-le'),term)


if __name__=='__main__':unittest.main()
