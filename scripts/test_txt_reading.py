"""Offline TXT read contracts and private native-preflight boundaries."""
from contextlib import redirect_stdout
from copy import deepcopy
import io
import json
import unittest
from unittest.mock import patch

from fetch_weread_epub import make_content_params
from mock_weread import shards
from test_web_source_progress import Opener
import verify_txt_reading as txt
from verify_owner_reading import TxtReadingPreflight, reading_position

BOOK = '900001'
POINT = dict(bookId=BOOK, chapterUid=2, chapterOffset=10, progress=20)
PLAIN = '\ufeffLiteral <tag> &amp; text must remain visible. 中文正文😀\r\n' * 12


def catalog():
    return dict(data=[dict(bookId=BOOK, book=dict(bookId=BOOK, format='txt'), bookVersion=7,
                           updated=[dict(chapterUid=1, wordCount=500), dict(chapterUid=2, wordCount=800)])])


def reader(chapter=1):
    value = dict(reader=dict(bookInfo=dict(bookId=BOOK), currentChapter=dict(chapterUid=chapter),
                            psvts='synthetic-txt-session'))
    return ('window.__INITIAL_STATE__=' + json.dumps(value) + ';(function(){})();').encode()


def rows(*, native=False):
    parts = [p.encode() for p in shards(PLAIN, count=2)]
    values = [catalog(), reader(2 if native else 1), dict(bookId=BOOK), *parts]
    if native:
        values.insert(1, dict(book=POINT))
        values = [dict(books=[dict(bookId=BOOK, format='txt')]), *values, catalog(), dict(book=POINT)]
    return values


def ready(values=None, *, native=False):
    web = TxtReadingPreflight() if native else txt.TxtProbe()
    web.authenticated, web.vid = True, '900000'
    opener = Opener(rows(native=native) if values is None else values)
    web.opener = opener
    return web, opener


class TxtReadingTests(unittest.TestCase):
    def test_default_never_opens_session_or_network(self):
        with patch.object(txt, 'SessionStore') as store, patch.object(txt, 'TxtProbe') as web, redirect_stdout(io.StringIO()) as out:
            self.assertEqual(txt.main([]), 0)
        store.assert_not_called(); web.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'], 'OFFLINE_ONLY')

    def test_marker_requires_same_book_and_chapter_and_success(self):
        self.assertTrue(txt.fallback_marker(json.dumps(dict(bookId=BOOK)), BOOK, '1'))
        self.assertFalse(txt.fallback_marker('encoded shard', BOOK, '1'))
        self.assertFalse(txt.fallback_marker('{}', BOOK, '1'))
        for change in (dict(bookId='900002'), dict(chapterUid=2), dict(errcode=-1), dict(errCode='-1'),
                       dict(errcode=False), dict(succ=False), dict(succ=0), dict(bookId=[])):
            with self.subTest(change=change), self.assertRaises((txt.TxtError, txt.PreflightError)):
                txt.fallback_marker(json.dumps(dict(dict(bookId=BOOK), **change)), BOOK, '1')

    def test_marker_has_bounded_input(self):
        for value in (None, ' ' * 65537):
            with self.assertRaises(txt.TxtError): txt.fallback_marker(value, BOOK, '1')

    def test_chapter_selection_requires_unique_readable_identity(self):
        values = [dict(chapterUid='bad/uid', wordCount=800), dict(chapterUid=1, wordCount=True),
                  dict(chapterUid=2, wordCount=float('nan')), dict(chapterUid=3, wordCount=800)]
        self.assertEqual(txt.select_chapter(values)['chapterUid'], '3')
        with self.assertRaises(txt.TxtError): txt.select_chapter(values, '2')
        with self.assertRaises(txt.TxtError): txt.select_chapter(values + [dict(chapterUid='3', wordCount=0)])

    def test_txt_reads_are_scoped_to_verified_marker_and_same_payload(self):
        web, _opener = ready([])
        web.book_id, web.chapter, web.psvts = BOOK, '1', 'synthetic-txt-session'
        params = make_content_params(BOOK, '1', web.psvts, sc=1)
        url = txt.BASE + '/web/book/chapter/t_0'
        with self.assertRaises(txt.PreflightError): web.guard('t_0', url, params)
        web.txt_scope = True
        web.guard('t_0', url, params)
        for changes in (dict(b='foreign'), dict(c='foreign'), dict(ps='stale'), dict(sc=True),
                        dict(sc=0), dict(st=True), dict(st=1), dict(prevChapter=0), dict(freeTrial=1)):
            with self.subTest(changes=changes), self.assertRaises(txt.PreflightError):
                web.guard('t_0', url, dict(params, **changes))
        for bad in (url + '?extra=1', url + '#fragment', url.replace('https:', 'http:'), url + '/extra'):
            with self.assertRaises(txt.PreflightError): web.guard('t_0', bad, params)

    def test_no_mutation_or_authentication_post_is_allowed(self):
        web, _opener = ready([])
        web.book_id, web.chapter, web.txt_scope = BOOK, '1', True
        for stage, path in (('read', '/web/book/read'), ('renew', '/web/login/renewal'),
                            ('shelf_add', '/web/shelf/add'), ('purchase', '/pay/buy'), ('trial', '/web/book/freeTrial')):
            with self.subTest(stage=stage), self.assertRaises(txt.PreflightError):
                web.guard(stage, txt.BASE + path, {})

    def test_real_decoder_preserves_raw_txt_and_literals(self):
        web, opener = ready()
        self.assertTrue(web.inspect_book(BOOK))
        self.assertEqual(web.sample['plain'], PLAIN)
        self.assertEqual(len(opener.calls), 5)

    def test_invalid_marker_stops_before_txt_requests(self):
        for marker in ({}, dict(bookId='900002'), dict(bookId=BOOK, errcode=-1)):
            values = rows(); values[2] = marker
            web, opener = ready(values)
            with self.assertRaises((txt.TxtError, txt.PreflightError)): web.inspect_book(BOOK)
            self.assertEqual(len(opener.calls), 3)
            self.assertFalse(web.txt_scope)

    def test_non_txt_catalog_does_not_fetch_reader_or_content(self):
        for kind in ('epub', 'pdf', None, 'unknown'):
            value = catalog(); value['data'][0]['book']['format'] = kind
            web, opener = ready([value])
            self.assertFalse(web.inspect_book(BOOK))
            self.assertEqual(len(opener.calls), 1)

    def test_new_inspection_revokes_previous_private_sample_and_session(self):
        web, _opener = ready()
        self.assertTrue(web.inspect_book(BOOK))
        value = catalog(); value['data'][0]['book']['format'] = 'epub'
        web.opener = Opener([value])
        self.assertFalse(web.inspect_book(BOOK))
        self.assertIsNone(web.sample)
        self.assertIsNone(web.psvts)
        self.assertIsNone(web.chapter)
        self.assertFalse(web.txt_scope)

    def test_bounded_sampling_prioritizes_txt_and_keeps_shelf_ids(self):
        shelf = dict(books=[dict(bookId=str(900002 + i), format='epub') for i in range(12)]
                     + [dict(bookId=BOOK, format='txt'), dict(bookId=BOOK, format='txt')])
        web, opener = ready([shelf])
        web.inspect_book = lambda key, _hint: key == BOOK
        self.assertTrue(web.find_sample(limit=1))
        self.assertEqual((len(opener.calls), web.shelf_count, len(web.shelf_ids)), (1, 14, 13))

    def test_native_preflight_uses_saved_chapter_and_literal_text(self):
        web, opener = ready(native=True)
        value = web.prepare()
        self.assertEqual(value['chapter_uid'], '2')
        self.assertEqual(value['source_format'], 'web_txt')
        self.assertIn('<tag> &amp;', value['source_text'])
        self.assertEqual(web.baseline, dict(chapter='2', offset=10, percent=20))
        self.assertEqual(len(opener.calls), 9)

    def test_native_preflight_rejects_changed_position_or_catalog(self):
        for key in ('position', 'chapter', 'version'):
            values = deepcopy(rows(native=True))
            if key == 'position': values[-1]['book'] = dict(POINT, chapterOffset=11)
            elif key == 'chapter': values[-2]['data'][0]['updated'][1]['wordCount'] = 999
            else: values[-2]['data'][0]['bookVersion'] = 8
            web, _opener = ready(values, native=True)
            with self.subTest(key=key), self.assertRaises(txt.PreflightError): web.prepare()

    def test_unavailable_saved_chapter_is_not_retargeted(self):
        values = rows(native=True); values[2] = dict(book=dict(POINT, chapterUid=9))
        web, opener = ready(values, native=True)
        with self.assertRaises(txt.TxtError): web.prepare()
        self.assertEqual(len(opener.calls), 3)

    def test_unstarted_txt_uses_first_readable_chapter_without_cloud_write(self):
        values = rows(native=True)
        empty = dict(bookId=BOOK, chapterUid=0, chapterOffset=0, chapterIdx=0, progress=0)
        values[2] = values[-1] = dict(book=empty)
        values[3] = reader(1)
        web, _opener = ready(values, native=True)
        self.assertEqual(web.prepare()['chapter_uid'], '1')
        self.assertEqual(web.baseline, dict(chapter='0', offset=0, percent=0))
        with self.assertRaises(txt.PreflightError): reading_position(dict(book=empty), BOOK)

    def test_unstarted_short_chapter_is_not_silently_skipped(self):
        values = rows(native=True)
        values[2] = dict(book=dict(bookId=BOOK, chapterUid=0, chapterOffset=0, progress=0))
        values[1]['data'][0]['updated'][0]['wordCount'] = 10
        web, opener = ready(values, native=True)
        with self.assertRaises(txt.TxtError): web.prepare()
        self.assertEqual(len(opener.calls), 3)

    def test_zero_start_still_rejects_api_errors_and_conflicting_aliases(self):
        empty = dict(bookId=BOOK, chapterUid=0, chapterOffset=0, chapterIdx=0, progress=0)
        for change in (dict(errcode=-1), dict(offset=1), dict(chapterId=2), dict(chapterIdx=3)):
            with self.subTest(change=change), self.assertRaises(ValueError if 'chapterIdx' not in change else txt.PreflightError):
                reading_position(dict(book=dict(empty, **change)), BOOK, allow_unstarted=True)


if __name__ == '__main__':
    unittest.main()
