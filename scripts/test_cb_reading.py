"""Synthetic-only CB_ chapter protocol and scope checks."""
from contextlib import redirect_stdout
from copy import deepcopy
import io
import json
import unittest
from unittest.mock import patch

from fetch_weread_epub import make_content_params, reader_url_for
from mock_weread import shards
from test_cb_progress import FIRST, SECOND
from test_web_source_progress import Opener
from verify_source_coordinates import CoordinateError, FilteredSource
import verify_cb_reading as cb

TEXT = 'A unique opening sentence anchors this synthetic chapter. ' + 'Independently written text. 中文与😀保持原样。' * 8
HTML = '<html><head><title>Private title</title></head><body><p>' + TEXT + '</p></body></html>'


def catalog(identity=FIRST):
    return [dict(bookId=identity, book=dict(bookId=identity), bookVersion=7,
                 updated=[dict(chapterUid=1, chapterIdx=1, title='One', wordCount=200),
                          dict(chapterUid=2, chapterIdx=2, title='Two', wordCount=300)])]


def point(identity=FIRST):
    return dict(book=dict(bookId=identity, chapterUid=2, chapterIdx=2, chapterOffset=10, progress=25))


def reader(identity=FIRST, chapter=2):
    return ('window.__INITIAL_STATE__=' + json.dumps(dict(reader=dict(bookInfo=dict(bookId=identity),
            currentChapter=dict(chapterUid=chapter), psvts='synthetic-cb-session'))) + ';(function(){})();').encode()


def responses(identity=FIRST, txt=False):
    parts = [part.encode() for part in shards(TEXT if txt else HTML, count=2 if txt else 3)]
    content = [dict(bookId=identity, chapterUid=2), *parts] if txt else parts
    return [catalog(identity), point(identity), reader(identity), *content, b'', catalog(identity), point(identity)]


def ready(rows=None):
    web = cb.CbReadingProbe(); web.vid = '900000'; web.authenticated = True
    web.allowed = {FIRST, SECOND}; web.book_id = FIRST; web.chapter = '2'; web.psvts = 'synthetic-cb-session'
    web.set_cookie('wr_vid', '900000'); web.set_cookie('wr_skey', 'synthetic-private-cookie')
    opener = Opener(responses() if rows is None else rows); web.opener = opener
    return web, opener


class CbReadingTests(unittest.TestCase):
    def test_default_is_offline_and_does_not_open_keychain(self):
        with patch.object(cb, 'SessionStore') as store, patch.object(cb, 'CbReadingProbe') as probe, redirect_stdout(io.StringIO()) as out:
            self.assertEqual(cb.main([]), 0)
        store.assert_not_called(); probe.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'], 'OFFLINE_ONLY')

    def test_only_selected_cb_read_stages_are_allowed_once(self):
        web, _opener = ready([])
        web.guard('reader', reader_url_for(FIRST, '2'), None)
        with self.assertRaises(cb.CbReadingError): web.guard('reader', reader_url_for(FIRST, '2'), None)
        for identity in ('41', 'CB_Unknown', 'CB_a/b'):
            web.book_id = identity
            with self.assertRaises(cb.CbReadingError): web.guard('reader', reader_url_for(identity, '2'), None)
        for stage, route in [('read', '/web/book/read'), ('renewal', '/web/login/renewal'), ('trial', '/web/book/freeTrial'),
                             ('purchase', '/pay/buy'), ('membership', '/web/shelf/add'), ('notes', '/web/book/underline')]:
            with self.assertRaises(cb.CbReadingError): web.guard(stage, cb.BASE + route, {})

    def test_content_payload_and_url_cannot_expand_scope(self):
        web, _opener = ready([]); params = make_content_params(FIRST, '2', web.psvts)
        for change in [dict(b='foreign'), dict(c='foreign'), dict(ps='other'), dict(sc=True), dict(st=1),
                       dict(prevChapter=0), dict(freeTrial=1)]:
            with self.assertRaises(cb.CbReadingError): web.guard('e_0', cb.BASE + '/web/book/chapter/e_0', dict(params, **change))
        for path in ['/web/book/chapter/e_0?extra=1', '/web/book/chapter/e_0#fragment', '/web/book/chapter/e_1']:
            with self.assertRaises(cb.CbReadingError): web.guard('e_0', cb.BASE + path, params)
        web.guard('e_0', cb.BASE + '/web/book/chapter/e_0', params)
        with self.assertRaises(cb.CbReadingError): web.guard('e_0', cb.BASE + '/web/book/chapter/e_0', params)

    def test_txt_and_style_have_separate_gates(self):
        web, _opener = ready([]); params = make_content_params(FIRST, '2', web.psvts)
        with self.assertRaises(cb.CbReadingError): web.guard('t_0', cb.BASE + '/web/book/chapter/t_0', params)
        with self.assertRaises(cb.CbReadingError): web.guard('e_2', cb.BASE + '/web/book/chapter/e_2', params)
        web.txt_scope = True
        web.guard('t_0', cb.BASE + '/web/book/chapter/t_0', params)
        web.guard('e_2', cb.BASE + '/web/book/chapter/e_2', make_content_params(FIRST, '2', web.psvts, style=True))

    def test_owner_cookie_change_stops_before_http(self):
        web, opener = ready([]); web.set_cookie('wr_vid', '900099')
        with self.assertRaises(Exception): web.request('reader', reader_url_for(FIRST, '2'), as_json=False)
        self.assertEqual(opener.calls, []); self.assertFalse(web.authenticated)

    def test_catalog_rejects_foreign_nested_identity_and_duplicate_or_missing_chapters(self):
        for change in ('foreign', 'duplicate', 'empty', 'invalid_uid'):
            value = catalog()
            if change == 'foreign': value[0]['book']['bookId'] = SECOND
            elif change == 'duplicate': value[0]['updated'] *= 2
            elif change == 'empty': value[0]['updated'] = []
            else: value[0]['updated'][0]['chapterUid'] = True
            with self.assertRaises(Exception): cb.readable_chapters(value, FIRST)

    def test_selection_uses_resume_or_normal_first_readable_without_skipping(self):
        _record, rows = cb.readable_chapters(catalog(), FIRST)
        self.assertEqual(cb.choose_chapter(rows, dict(chapter='2'))['chapterUid'], 2)
        self.assertEqual(cb.choose_chapter(rows, dict(chapter='0'))['chapterUid'], 1)
        with self.assertRaises(cb.CbReadingError): cb.choose_chapter(rows, dict(chapter='9'))
        self.assertEqual(cb.baseline_position(dict(bookId=FIRST, chapterUid=0, chapterIdx=0, chapterOffset=0, progress=0), FIRST)['chapter'], '0')
        with self.assertRaises(Exception): cb.baseline_position(point(SECOND), FIRST)

    def test_txt_marker_requires_the_same_book_chapter_and_explicit_success(self):
        self.assertFalse(cb.txt_marker('encoded-content', FIRST, '2'))
        self.assertTrue(cb.txt_marker(json.dumps(dict(bookId=FIRST, chapterUid=2)), FIRST, '2'))
        for value in ({}, dict(bookId=SECOND), dict(bookId=FIRST, chapterUid=1), dict(bookId=FIRST, errCode=-1),
                      dict(bookId=FIRST, succ=False), dict(bookId=FIRST, errcode=False)):
            with self.assertRaises(cb.CbReadingError): cb.txt_marker(json.dumps(value), FIRST, '2')

    def test_real_epub_decoder_and_source_sample_remain_private(self):
        web, opener = ready(); sample = web.inspect(FIRST)
        self.assertEqual(sample['source'], HTML); self.assertEqual(sample['source_format'], 'web_xhtml')
        self.assertEqual(sample['chapter_uid'], '2'); self.assertEqual(len(opener.calls), 9)
        self.assertEqual(web.samples, [sample]); self.assertEqual(sample['baseline'], dict(chapter='2', offset=10, percent=25))

    def test_real_txt_decoder_preserves_literal_text(self):
        web, opener = ready(responses(txt=True)); sample = web.inspect(FIRST)
        self.assertEqual(sample['source'], TEXT); self.assertEqual(sample['source_format'], 'web_txt')
        self.assertEqual(len(opener.calls), 9)

    def test_anchor_selection_can_use_another_paragraph_in_the_same_chapter(self):
        repeated = 'A repeated preface line is longer than thirty two characters.'
        raw = '<body><p>' + repeated + '</p><p>' + repeated + '</p><p>' + TEXT + '</p></body>'
        text, offset = cb.source_sample(raw, 'web_xhtml')
        self.assertEqual(text, TEXT[:32]); self.assertGreater(offset, 0)
        with self.assertRaises(cb.CbReadingError): cb.source_sample('<body><p>' + repeated * 2 + '</p></body>', 'web_xhtml')

    def test_explicit_ordinal_is_bound_to_the_full_shelf_set(self):
        rows = [dict(books=[dict(bookId=SECOND), dict(bookId=FIRST)])] + responses(SECOND)
        web, opener = ready(rows); sample = web.prepare(2)[0]
        self.assertEqual(sample['book_id'], SECOND); self.assertEqual(len(opener.calls), 10)
        web, opener = ready([rows[0]])
        with self.assertRaises(cb.CbReadingError): web.prepare(3)
        self.assertEqual(len(opener.calls), 1)

    def test_multiple_bodies_are_local_opt_in_and_preserve_original_offsets(self):
        first = '<html><body><p>A uniquely written first body with 中文😀 and entities &amp;.</p></body></html>'
        second = '<html><head><title>Ignored heading</title></head><body><p>' + TEXT + '</p></body></html>'
        raw = first + second
        with self.assertRaises(CoordinateError): FilteredSource(raw)
        model = FilteredSource(raw, allow_multiple_bodies=True)
        expected = len((first + second[:second.index(TEXT)]).encode('utf-16-le')) // 2
        self.assertEqual(model.locate(TEXT[:32])[0], expected)
        self.assertEqual(model.anchor_at(expected)[:32], TEXT[:32])
        self.assertEqual(cb.source_sample(raw, 'web_xhtml')[0], 'A uniquely written first body wi')

    def test_local_multiple_bodies_reject_nested_unbalanced_or_excessive_documents(self):
        for raw in ('<body>one<body>nested</body></body>', '<body>one</body></body>', '<body>open',
                    '<body/>', '<body>bad\0control</body>', '<body>x</body>' * 257,
                    '<!-- <body> --><body>one</body>'):
            with self.assertRaises(CoordinateError): FilteredSource(raw, allow_multiple_bodies=True)

    def test_foreign_reader_or_changed_catalog_or_position_stops_without_retry(self):
        for index, value in [(2, reader(SECOND)), (7, catalog(SECOND)), (8, dict(book=dict(point()['book'], chapterOffset=11)))]:
            rows = responses(); rows[index] = value; web, opener = ready(rows)
            with self.assertRaises(Exception): web.inspect(FIRST)
            self.assertEqual(web.samples, []); self.assertLessEqual(len(opener.calls), index + 1)

    def test_complete_shelf_sample_is_bounded_and_does_not_skip_a_failure(self):
        rows = [dict(books=[dict(bookId=FIRST), dict(bookId=SECOND)])] + responses(FIRST) + responses(SECOND)
        web, opener = ready(rows); samples = web.prepare()
        self.assertEqual(len(samples), 2); self.assertEqual(len(opener.calls), 19)
        bad = deepcopy(rows); bad[3] = reader(SECOND); web, opener = ready(bad)
        with self.assertRaises(Exception): web.prepare()
        self.assertEqual(len(opener.calls), 4); self.assertEqual(web.samples, [])

    def test_cli_report_contains_only_counts_and_fixed_statuses(self):
        web, _opener = ready([dict(books=[dict(bookId=FIRST)])] + responses())
        saved = dict(vid='900000', cookies=dict(wr_vid='900000', wr_skey='synthetic-private-cookie'))
        with patch.object(cb, 'SessionStore') as store, patch.object(cb, 'CbReadingProbe', return_value=web), \
             patch.object(web, 'verify_account'), patch.object(cb, 'save_refreshed_web_session', return_value=False), redirect_stdout(io.StringIO()) as out:
            store.return_value.load.return_value = saved
            self.assertEqual(cb.main(['--saved-session']), 0)
        report = json.loads(out.getvalue())
        self.assertEqual(report['result'], 'CB_CHAPTER_READ_VERIFIED'); self.assertEqual(report['completed_books'], 1)
        self.assertEqual(report['read_only_query_posts'], 6); self.assertEqual(report['account_data_posts'], 0)
        for private in (FIRST, TEXT, 'synthetic-cb-session', 'synthetic-private-cookie', '900000'):
            self.assertNotIn(private, out.getvalue())
        self.assertEqual(saved, {}); self.assertEqual(web.samples, []); store.return_value.delete.assert_not_called()


if __name__ == '__main__':
    unittest.main()
