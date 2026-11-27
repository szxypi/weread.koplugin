"""Synthetic checks for the real-source, memory-only full-search verifier."""
from contextlib import redirect_stdout
import io
import json
import unittest
from unittest.mock import patch

from test_cb_full_reading import FIRST, HTML, responses
from test_web_source_progress import Opener
from verify_source_coordinates import FilteredSource
import verify_owner_full_cached_search as target


class FullCachedSearchTests(unittest.TestCase):
    def test_default_is_offline_and_does_not_load_credentials(self):
        with patch.object(target,'SessionStore') as store, patch.object(target,'MemoryFullProbe') as probe, redirect_stdout(io.StringIO()) as out:
            self.assertEqual(target.main([]),0)
        store.assert_not_called();probe.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_full_probe_collects_only_validated_source_in_memory(self):
        web=target.MemoryFullProbe(interval=0)
        web.vid='900000';web.authenticated=True;web.set_cookie('wr_vid','900000');web.set_cookie('wr_skey','private-cookie')
        web.opener=Opener(responses())
        sample=web.prepare(1)
        self.assertEqual(set(web.private_sources),{'1','2'})
        self.assertEqual(web.private_sources['1'],HTML)
        self.assertEqual(web.private_sources['2'],HTML)
        self.assertEqual(web.private_shards,{})
        self.assertEqual(len(web.catalog_snapshot[0]),2)
        self.assertIsInstance(web.shelf_hash,str)
        self.assertNotIn('source',sample)
        self.assertEqual(sample['book_id'],FIRST)

    def test_query_is_unique_across_the_full_book_and_maps_to_source(self):
        first='<html><body><p>春风穿过树林溪流缓缓流向山脚下的宁静村庄今天阳光明亮。</p></body></html>'
        second='<html><body><p>这是一段完全不同的合成章节用于保证搜索范围的完整性。</p></body></html>'
        uid,keyword,offset=target.unique_query({'1':first,'2':second},'1')
        self.assertEqual(uid,'1')
        self.assertIn(keyword,first);self.assertNotIn(keyword,second)
        self.assertEqual(FilteredSource(first,allow_multiple_bodies=True).locate(keyword)[0],offset)
        with self.assertRaises(ValueError):target.unique_query({'1':first,'2':first},'1')

    def test_alternate_chapter_is_chosen_when_the_preferred_only_repeats(self):
        repeated = '<html><body><p>春风穿过树林溪流缓缓流向山脚下的宁静村庄今天阳光明亮。</p>'
        first = repeated + '</body></html>'
        other = repeated + '<p>这是整书只有另一章中出现的唯一正文搜索定位段落。</p></body></html>'
        uid, keyword, offset = target.unique_query({'1':first,'2':other},'1')
        self.assertEqual(uid,'2')
        self.assertNotIn(keyword,first)
        self.assertEqual(FilteredSource(other,allow_multiple_bodies=True).locate(keyword)[0],offset)

    def test_overlapping_matches_are_rejected(self):
        overlapping = '<html><body><p>' + 'a' * 17 + '</p></body></html>'
        other = '<html><body><p>结尾</p></body></html>'
        with self.assertRaisesRegex(ValueError,'search_no_unique_query'):
            target.unique_query({'1':overlapping,'2':other},'1')

    def test_unsupported_chapter_prevents_a_claim_of_corpus_uniqueness(self):
        first = '<html><body><p>这是整书其他章节里未出现的合成关键字定位段落。</p></body></html>'
        with self.assertRaisesRegex(ValueError,'search_source_projection'):
            target.unique_query({'1':first,'2':'invalid XHTML'},'1')


if __name__=='__main__':unittest.main()
