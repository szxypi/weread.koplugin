"""Boundary inspection is offline by default and uses independent text runs."""
import contextlib
import io
import json
import unittest
from unittest.mock import patch
from urllib.parse import urlencode

import verify_cb_search_boundaries as task


class CBBoundarySearchTests(unittest.TestCase):
    def test_default_is_offline(self):
        for args in ([],['--native-ui']):
            output=io.StringIO()
            with patch.object(task,'SessionStore',side_effect=AssertionError('credentials')):
                with patch.object(task,'BoundaryProbe',side_effect=AssertionError('network')):
                    with contextlib.redirect_stdout(output):self.assertEqual(task.main(args),0)
            self.assertEqual(json.loads(output.getvalue()),{'result':'OFFLINE_ONLY','account_data_posts':0,
                'authentication_posts':0,'search_gets':0})

    def test_query_never_crosses_retained_tag(self):
        raw='<html><body><p>甲乙丙丁</p><p>戊己庚辛</p></body></html>'
        queries=task.segment_queries(raw)
        self.assertEqual(len(queries),1)
        self.assertEqual(queries[0][0],'甲乙丙丁')

    def test_each_query_has_a_separate_one_shot_budget(self):
        probe=task.BoundaryProbe();probe.authenticated=True;probe.vid='900000';probe.book_id='CB_Synthetic1'
        probe.allowed={probe.book_id};probe.chapter='7';probe.first_chapter='7';probe.keyword='合成文字';probe.search_cursor={'chapter':'7','start':0,'finish':0}
        probe.search_url=task.BASE+'/web/book/search_v2?'+urlencode(dict(bookId=probe.book_id,chapterUid='7',
            keyword=probe.keyword,posBegin=0,posEnd=0,mode='scrollDown',count=50))
        try:
            probe.guard('segment_1_current',probe.search_url,None)
            probe.guard('segment_1_first',probe.search_url,None)
            with self.assertRaisesRegex(ValueError,'search_repeated'):probe.guard('segment_1_current',probe.search_url,None)
            with self.assertRaises(ValueError):probe.guard('segment_2_current',probe.search_url+'&extra=1',None)
            with self.assertRaises(ValueError):probe.guard('segment_2_current',probe.search_url,{})
            probe.first_chapter='8'
            with self.assertRaises(ValueError):probe.guard('segment_2_first',probe.search_url,None)
        finally:probe.close()


if __name__=='__main__':unittest.main()
