"""Read-only selection must not turn partial or conflicting data into authority."""
import unittest
from copy import deepcopy
from types import SimpleNamespace
from unittest.mock import patch

import ordinary_reconnect_selection as selection
import verify_ordinary_reconnect_preview as preview


def record(book='900001', **changes):
    value = dict(bookId=book, chapterUid=4, chapterIdx=2, chapterOffset=10,
                 progress=25, summary='short')
    value.update(changes)
    return dict(book=value)


class FakeWeb:
    authenticated = True
    def __init__(self, records):
        self.records = records
        self.book_id = None
        self.calls = []
    def request(self, stage, url):
        self.calls.append((stage, self.book_id))
        if stage == 'shelf':
            return {'books': [{'bookId': book} for book in self.records]}
        if stage != 'selection_progress':
            raise AssertionError('unexpected network request')
        return deepcopy(self.records[self.book_id])


class ScreeningTests(unittest.TestCase):
    def test_skips_missing_and_long_summaries_and_stops_at_limit(self):
        missing = record('1'); del missing['book']['summary']
        web = FakeWeb({'1': missing, '2': record('2', summary='a'*21),
                       '3': record('3'), '4': record('4'), '5': record('5')})
        candidates, counts, shelf_count = selection.screen(web)
        self.assertEqual(candidates, ['3', '4'])
        self.assertEqual(counts, dict(checked=4, missing_position=0, missing_summary=1,
                                     long_summary=1, incomplete_position=0, candidates=2))
        self.assertEqual(shelf_count, 5)
        self.assertEqual(len(web.calls), 5)

    def test_incomplete_or_ambiguous_positions_do_not_become_candidates(self):
        no_index = record('1'); del no_index['book']['chapterIdx']
        no_uid = record('2'); del no_uid['book']['chapterUid']
        web = FakeWeb({'1': no_index, '2': no_uid, '3': record('3', progress=12.5), '4': {}})
        candidates, counts, _ = selection.screen(web)
        self.assertEqual(candidates, [])
        self.assertEqual(counts['incomplete_position'], 3)
        self.assertEqual(counts['missing_position'], 1)
        web = FakeWeb({'1': {'books': [record('1')['book'], record('1')['book']]}})
        with self.assertRaises(selection.ProgressError):
            selection.screen(web)

    def test_requires_authenticated_bounded_scope(self):
        web = FakeWeb({'1': record('1')})
        for options in ({'limit': 0}, {'limit': 129}, {'limit': True}, {'max_candidates': 0}, {'max_candidates': True}):
            with self.subTest(options=options), self.assertRaises(ValueError):
                selection.screen(web, **options)
        web.authenticated = False
        with self.assertRaises(ValueError): selection.screen(web)
        self.assertEqual(web.calls, [])

    def test_selection_skips_only_known_unsuitable_source(self):
        web = preview.RestorablePreflight()
        self.addCleanup(web.close)
        expected = {'checked': 2, 'candidates': 2}
        with patch.object(preview, 'screen', return_value=(['1', '2'], expected, 2)), \
             patch.object(preview.CapturedPreflight, 'prepare', side_effect=[ValueError('progress_preview_no_adjacent_point'), {'ok': True}]):
            self.assertEqual(web.prepare(), {'ok': True})
            self.assertEqual(web.selected_book, '2')
        with patch.object(preview, 'screen', return_value=(['1', '2'], expected, 2)), \
             patch.object(preview.CapturedPreflight, 'prepare', side_effect=ValueError('http_rejected')) as prepare:
            with self.assertRaisesRegex(ValueError, 'http_rejected'): web.prepare()
            self.assertEqual(prepare.call_count, 1)


if __name__ == '__main__':
    unittest.main()
