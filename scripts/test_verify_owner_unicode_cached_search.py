"""Offline isolation and source-coordinate checks for real-source search proof."""
from contextlib import redirect_stdout, redirect_stderr
import io
import json
import unittest
from unittest.mock import patch
import unicodedata

from verify_source_coordinates import FilteredSource
import verify_owner_unicode_cached_search as task


class OwnerUnicodeSearchTests(unittest.TestCase):
    def test_offline_default_does_not_load_sessions(self):
        with patch.object(task,'SessionStore',side_effect=AssertionError('unexpected session')),redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_unique_fullwidth_query_binds_to_original_source(self):
        raw='<html><body><p>合成前文 UniqueSentence 原文结束。</p></body></html>'
        keyword,offset=task.find_query(raw)
        self.assertEqual(unicodedata.normalize('NFKC',keyword).casefold(),'uniquesentence')
        self.assertEqual(offset,FilteredSource(raw,allow_multiple_bodies=True).locate('UniqueSentence')[0])
        self.assertTrue(all(ord(char)>127 for char in keyword))

    def test_canonical_query_uses_original_coordinate(self):
        raw='<html><body><p>合成前文独特 CaféReadingSegment 后文结束。</p></body></html>'
        keyword,offset=task.find_canonical_query(raw)
        self.assertNotEqual(keyword,unicodedata.normalize('NFC',keyword))
        model=FilteredSource(raw,allow_multiple_bodies=True)
        self.assertIn(offset,model.starts)
        self.assertIn('e\u0301',keyword)

    def test_canonical_discovery_checks_beyond_initial_text_window(self):
        raw='<html><body><p>'+('汉'*20010)+'独特前文 CaféReadingSegment 尾部。</p></body></html>'
        query,offset=task.find_canonical_query(raw)
        self.assertIn('e\u0301',query)
        self.assertGreater(offset,20000)

    def test_canonical_query_requires_a_real_decomposable_letter(self):
        raw='<html><body><p>合成普通 EnglishOnly Text without accents.</p></body></html>'
        self.assertIsNone(task.find_canonical_query(raw))

    def test_casefold_duplicates_are_not_chosen(self):
        raw='<html><body><p>qabcdefgh隔qABCDEFGH</p></body></html>'
        self.assertIsNone(task.find_query(raw))

    def test_compatibility_variant_is_treated_as_duplicate(self):
        raw='<html><body><p>qabcdefgh隔ＱＡＢＣＤＥＦＧＨ</p></body></html>'
        self.assertIsNone(task.find_query(raw))

    def test_candidate_mismatch_stops_before_loading_credentials(self):
        candidate='/validation/cb-dry-candidate-'+'a'*64+'.zip'
        other='/validation/cb-dry-candidate-'+'b'*64+'.zip'
        with patch.object(task,'trusted_command',return_value=['test',other]), \
                patch.object(task,'SessionStore',side_effect=AssertionError('unexpected session')),redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main(['--saved-session','--candidate',candidate]),1)
        result=json.loads(out.getvalue())
        self.assertEqual((result['result'],result['phase'],result['account_data_writes']),('UNVERIFIED','candidate_attestation',0))

    def test_saved_session_requires_candidate_before_opening_session(self):
        with patch.object(task,'SessionStore',side_effect=AssertionError('unexpected session')),redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):task.main(['--saved-session'])
            with self.assertRaises(SystemExit):task.main(['--saved-session','--candidate','/validation/../private'])


if __name__=='__main__':unittest.main()
