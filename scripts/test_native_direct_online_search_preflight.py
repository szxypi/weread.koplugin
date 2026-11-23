"""Check account-free online-search preflight filtering and pagination."""
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import native_direct_online_search_preflight as task
from verify_source_coordinates import FilteredSource


class PreflightTests(unittest.TestCase):
    def setUp(self):
        self.raw='<html><body><p>第一行独特的中文内容用于搜索边界验证和查找结果。</p></body></html>'
        model=FilteredSource(self.raw);text=''.join(model.characters);self.keyword=text[:12]
        self.start,self.finish=model.starts[0],model.ends[11]
        self.calls=[]
        self.web=SimpleNamespace(verify_account=lambda:None,request=self.request)
        self.more=False;self.invalid=False

    def request(self,stage,*_args,**_kwargs):
        self.calls.append(stage)
        if stage=='reader':return 'reader'
        if stage in ('e_0','e_1','e_3'):return stage
        if stage=='catalog_before':return 'catalog'
        if stage=='search_probe':
            if self.invalid:return {'scrollDownHasMore':1,'results':[]}
            if self.more and self.calls.count('search_probe')==1:
                return {'scrollDownHasMore':1,'results':[dict(chapterUid=1,posBegin=1,posEnd=2,matchWords=[])]}
            return {'scrollDownHasMore':0,'results':[dict(chapterUid=2,posBegin=self.start,posEnd=self.finish,
                matchWords=[dict(word=self.keyword,posBegin=self.start,posEnd=self.finish)])]}
        raise AssertionError(stage)

    def run_prepare(self,source=None):
        with patch.object(task,'read_reader_state',return_value=SimpleNamespace(psvts='fixture')),\
                patch.object(task,'make_content_params',return_value={}),patch.object(task,'decode_content_shards',return_value=self.raw),\
                patch.object(task,'normalize_chapter_infos',return_value=({},[dict(chapterUid=1,title='First',wordCount=10),
                    dict(chapterUid=2,title='Second',wordCount=10)])):
            return task.prepare(self.web,'42','2',self.raw.encode() if source is None else source)

    def test_only_matching_source_and_exact_result_pass(self):
        result=self.run_prepare()
        self.assertEqual(result['keyword'],self.keyword)
        self.assertEqual(result['allowed'],[dict(chapter='1',start=0,finish=0)])
        self.assertEqual((result['start'],result['finish']),(self.start,self.finish))
        with self.assertRaisesRegex(ValueError,'source_changed'):self.run_prepare(b'different')

    def test_bounded_pagination_and_invalid_empty_page(self):
        self.more=True;result=self.run_prepare()
        self.assertEqual(len(result['allowed']),2)
        self.assertEqual(result['allowed'][1],dict(chapter='1',start=1,finish=2))
        self.calls=[];self.invalid=True
        with self.assertRaisesRegex(ValueError,'no_target'):self.run_prepare()


if __name__=='__main__':unittest.main()
