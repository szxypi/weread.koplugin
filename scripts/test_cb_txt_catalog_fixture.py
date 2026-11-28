import contextlib
import io
import json
import unittest
from unittest.mock import patch

from test_personal_upload_trial import FakeProbe
from test_secure_native_session import Backend, credentials
import verify_cb_txt_catalog_fixture as task
from verify_cb_txt_fixture import Receipt


class TxtCatalogFixtureTests(unittest.TestCase):
    def test_offline_never_opens_account(self):
        with patch.object(task, 'SessionStore', side_effect=AssertionError('opened')):
            with contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(task.main([]), 0)
        self.assertEqual(json.loads(output.getvalue())['result'], 'OFFLINE_ONLY')

    def test_counts_distinguish_missing_zero_and_invalid(self):
        rows = [{}, {'wordCount': None}, {'wordCount': 0}, {'wordCount': 2}, {'wordCount': '7'},
                {'wordCount': True}, {'wordCount': float('nan')}, {'wordCount': float('inf')}]
        self.assertEqual(task.catalog_counts(rows), dict(catalog_chapters=8, count_missing=2,
                         count_zero=1, count_positive=1, count_invalid=4))

    def test_unique_fixture_cleanup_and_no_replay(self):
        journal = task.Journal(Backend()); receipt = Receipt(Backend()); probe = FakeProbe()
        class Prior:
            def read(self): return {'target': 'CB_previousfixture'}, 'stable'
        with patch.object(task, 'GroupJournal', Prior):
            result = task.execute(probe, journal, receipt, credentials(), lambda *_: True, lambda _: True,
                                  lambda: True, apply=True, sleep=lambda _: None, now=lambda: 1000)
        self.assertEqual(result['result'], 'TXT_IMPORT_AND_SOURCE_VERIFIED')
        self.assertEqual(tuple(probe.attempts.values()), (1, 1, 1, 1))
        self.assertEqual(journal.read()[0]['phase'], 'restored')
        with self.assertRaises(ValueError):
            task.execute(probe, journal, receipt, credentials(), lambda *_: True, lambda _: True, lambda: True, apply=True)
        self.assertEqual(tuple(probe.attempts.values()), (1, 1, 1, 1))

    def test_prior_fixture_is_never_removed(self):
        journal = task.Journal(Backend()); receipt = Receipt(Backend()); probe = FakeProbe()
        class Prior:
            def read(self): return {'target': 'CB_synthetic123'}, 'stable'
        with patch.object(task, 'GroupJournal', Prior):
            result = task.execute(probe, journal, receipt, credentials(), lambda *_: True, lambda _: True,
                                  lambda: True, apply=True, sleep=lambda _: None, now=lambda: 1000)
        self.assertEqual(result['result'], 'UNVERIFIED')
        self.assertEqual(probe.attempts['cleanup'], 0)
        self.assertEqual(journal.read()[0]['phase'], 'imported')

    def test_missing_count_source_is_checked_without_fabrication(self):
        class Web:
            def __init__(self): self.samples=[]; self.closed=False; self.allowed=set()
            def set_cookie(self, *_): pass
            def verify_account(self): pass
            def close(self): self.closed=True
            def request(self, stage, _url, _body=None, **_kwargs):
                if stage.startswith('catalog_'):
                    return [{'bookId': 'CB_Synthetic', 'updated': [{'chapterUid': 7, 'chapterIdx': 0, 'title': 'Text'}]}]
                if stage.startswith('progress_'): return {}
                return 'synthetic'
        web=Web(); summary={}
        with patch.object(task, 'baseline_position', return_value={'chapter': '0', 'offset': 0, 'percent': 0}), \
             patch.object(task, 'reader_context', return_value={'current_chapter': {'chapterUid': 7}, 'psvts': 'session'}), \
             patch.object(task, 'txt_marker', return_value=True), \
             patch.object(task, 'decode_content_shards', return_value=task.MARKER):
            result = task.read_fixture({'vid': '900000', 'cookies': {}}, 'CB_Synthetic', summary, factory=lambda: web)
        self.assertTrue(result and web.closed)
        self.assertEqual(summary['count_missing'], 1)
        self.assertTrue(summary['catalog_and_position_unchanged'])
        self.assertNotIn(task.MARKER, json.dumps(summary))

    def test_versioned_source_check_is_bound_to_chapter_and_owner(self):
        class Cookie:
            def __init__(self, name, value):
                self.name, self.value, self.domain, self.path=name, value, '.weread.qq.com', '/'
        class Web:
            def __init__(self):
                self.samples=[]; self.closed=False
                self.cookies=[Cookie('wr_vid', '900000'), Cookie('wr_skey', 'synthetic')]
            def set_cookie(self, *_): pass
            def verify_account(self): pass
            def close(self): self.closed=True
            def request(self, stage, _url, _body=None, **_kwargs):
                if stage.startswith('catalog_'):
                    return [{'bookId': 'CB_Synthetic', 'updated': [{'chapterUid': 7, 'chapterIdx': 0, 'wordCount': 10}]}]
                if stage.startswith('progress_'): return {}
                return 'synthetic'
        web=Web(); summary={}; calls=[]
        def verify(expected, saved, version):
            calls.append((expected, saved, version)); return True
        with patch.object(task, 'baseline_position', return_value={'chapter': '0', 'offset': 0, 'percent': 0}), \
             patch.object(task, 'reader_context', return_value={'current_chapter': {'chapterUid': 7}, 'psvts': 'session'}), \
             patch.object(task, 'txt_marker', return_value=False), \
             patch.object(task, 'decode_content_shards', return_value=task.MARKER):
            result=task.read_fixture({'vid': '900000', 'cookies': {}}, 'CB_Synthetic', summary,
                                     factory=lambda: web, chapter_uid='7', verify_source=verify, expected_version=7)
        self.assertTrue(result and web.closed and summary['koreader_source_match'])
        self.assertEqual(calls[0][0]['chapter_uid'], '7')
        self.assertEqual(calls[0][0]['raw_bytes'], len(task.MARKER.encode()))
        self.assertEqual(calls[0][1]['vid'], '900000'); self.assertEqual(calls[0][2], 7)

    def test_removed_fixture_is_receipt_bound_and_only_read(self):
        journal=task.Journal(Backend()); receipt=Receipt(Backend()); probe=FakeProbe(); grant=credentials()
        class Prior:
            def read(self): return {'target': 'CB_previousfixture'}, 'stable'
        with patch.object(task, 'GroupJournal', Prior):
            result=task.execute(probe, journal, receipt, grant, lambda *_: True, lambda _: True,
                                lambda: True, apply=True, sleep=lambda _: None, now=lambda: 1000)
        self.assertEqual(result['result'], 'TXT_IMPORT_AND_SOURCE_VERIFIED')
        target=journal.read()[0]['target']; saved={'vid': grant['vid'], 'cookies': {}}
        class Web:
            def set_cookie(self, *_): pass
            def verify_account(self): pass
            def close(self): pass
            def request(self, stage, _url, _body=None):
                if stage=='shelf': return {'books': [{'bookId': 'CB_Other'}]}
                return [{'bookId': target, 'book': {'bookId': target, 'bookVersion': 7},
                         'updated': [{'chapterUid': 1, 'chapterIdx': 0, 'wordCount': 10}]}]
        class Native:
            def request(self, stage, _url, credentials=None):
                assert stage=='metadata' and credentials==grant
                return {'bookId': target, 'bookVersion': 7}
        class Shelf:
            def request(self, stage, _url, credentials=None):
                assert stage=='shelf_full' and credentials==grant
                return {'books': [{'bookId': 'CB_Other'}]}
        def compare(identity, catalog, version):
            self.assertEqual(identity, target); self.assertEqual(version, 7)
            self.assertIsInstance(catalog, list)
            return dict(chapters=1, matching_version=True, chapter_indexes_valid=True, unversioned_rejected=True)
        result=task.removed_fixture(saved, grant, lambda: True, journal, receipt,
                                    web_factory=Web, native_factory=Native, shelf_factory=Shelf, compare=compare)
        self.assertTrue(result['web_and_native_positive_match'] and result['both_shelves_exclude_fixture'])
        self.assertEqual(result['independent_reads'], 2)
        self.assertNotIn(target, json.dumps(result))
        def source_reader(_saved, identity, summary, *, chapter_uid, expected_catalog, verify_source, expected_version):
            self.assertEqual(identity, target); self.assertEqual(chapter_uid, '1')
            self.assertIsInstance(expected_catalog, list)
            self.assertTrue(callable(verify_source)); self.assertEqual(expected_version, 7)
            summary.update(source_format='web_xhtml', source_marker_found=True, koreader_source_match=True); return True
        result=task.removed_fixture(saved, grant, lambda: True, journal, receipt, web_factory=Web,
                                    native_factory=Native, shelf_factory=Shelf, compare=compare,
                                    source_reader=source_reader, all_sources=True)
        self.assertEqual(result['chapter_sources_checked'], 1)
        self.assertEqual(result['source_formats'], {'web_txt': 0, 'web_xhtml': 1})
        with self.assertRaises(ValueError):
            task.removed_fixture(saved, grant, lambda: True, journal, receipt, web_factory=Web,
                                 native_factory=Native, shelf_factory=Shelf, compare=compare,
                                 source_reader=lambda *_a, **_k: False, all_sources=True)
        def unproven(_saved, _identity, summary, **_kwargs):
            summary.update(source_format='web_xhtml', source_marker_found=True); return True
        with self.assertRaises(ValueError):
            task.removed_fixture(saved, grant, lambda: True, journal, receipt, web_factory=Web,
                                 native_factory=Native, shelf_factory=Shelf, compare=compare,
                                 source_reader=unproven, all_sources=True)
        class PresentShelf:
            def request(self, *_args, **_kwargs): return {'books': [{'bookId': target}]}
        with self.assertRaises(ValueError):
            task.removed_fixture(saved, grant, lambda: True, journal, receipt,
                                 web_factory=Web, native_factory=Native, shelf_factory=PresentShelf, compare=compare)
        receipt.backend.save(b'{}')
        with self.assertRaises(ValueError):
            task.removed_fixture(saved, grant, lambda: True, journal, receipt,
                                 web_factory=Web, native_factory=Native, shelf_factory=Shelf, compare=compare)


if __name__ == '__main__': unittest.main()
