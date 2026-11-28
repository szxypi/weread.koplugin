from contextlib import redirect_stdout
from copy import deepcopy
import io
import json
import unittest
from unittest.mock import patch

import verify_cb_readable_catalog as task


class FakeWeb:
    shelf_reads = 0
    altered_shelf = False
    closes = 0
    def set_cookie(self, _name, _value): pass
    def verify_account(self): return True
    def close(self): FakeWeb.closes += 1
    def request(self, stage, _url, body=None):
        if stage == 'shelf':
            FakeWeb.shelf_reads += 1
            if FakeWeb.altered_shelf and FakeWeb.shelf_reads == 2:
                return {'books': [{'bookId': 'CB_Other'}]}
            return {'books': [{'bookId': 'CB_Synthetic'}]}
        assert stage == 'catalog_before' and body == {'bookIds': ['CB_Synthetic']}
        return [{'bookId': 'CB_Synthetic', 'updated': [
            {'chapterUid': 1, 'wordCount': 10, 'title': '封面'},
            {'chapterUid': 2, 'wordCount': 0, 'title': 'Synthetic heading'},
            {'chapterUid': 3, 'wordCount': 11, 'title': 'Synthetic chapter'},
        ]}]


class ReadableCatalogTest(unittest.TestCase):
    def setUp(self):
        FakeWeb.shelf_reads = FakeWeb.closes = 0
        FakeWeb.altered_shelf = False
        self.saved = {'vid': '900000', 'cookies': {'wr_vid': '900000'}}

    def test_readability_and_invalid_values(self):
        for value, title, expected in ((12, 'chapter', True), ('5', 'chapter', True),
                                       (1, '封面', False), (0, 'chapter', False), (None, None, False)):
            self.assertIs(task.readable({'wordCount': value, 'title': title}), expected)
        for value in (True, [], 'bad', float('inf')):
            with self.assertRaises(ValueError): task.readable({'wordCount': value})

    def test_read_only_compare_and_shelf_recheck(self):
        captured = []
        def compare(samples):
            captured.extend(deepcopy(samples))
            return dict(matches=True, catalogs=1, total_rows=3, excluded_rows=2)
        result = task.inspect(self.saved, lambda: True, factory=FakeWeb, compare=compare)
        self.assertEqual(result, dict(matches=True, catalogs=1, total_rows=3, excluded_rows=2))
        self.assertEqual(captured[0]['expected'], [False, False, True])
        self.assertEqual(FakeWeb.closes, 3)
        FakeWeb.shelf_reads = 0; FakeWeb.altered_shelf = True
        with self.assertRaises(ValueError): task.inspect(self.saved, lambda: True, factory=FakeWeb, compare=compare)

    def test_runtime_mismatch_and_session_change_fail(self):
        with self.assertRaises(ValueError):
            task.inspect(self.saved, lambda: True, factory=FakeWeb, compare=lambda _: {})
        with self.assertRaises(ValueError):
            task.inspect(self.saved, lambda: False, factory=FakeWeb, compare=lambda _: {})

    def test_offline_does_not_load_account(self):
        with patch.object(task, 'SessionStore') as session, redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]), 0)
        session.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'], 'OFFLINE_ONLY')


if __name__ == '__main__': unittest.main()
