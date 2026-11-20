#!/usr/bin/env python3
"""Offline safety and projection tests; never contacts WeRead."""
import unittest

import verify_progress_catalog_quality as check


class Store:
    def __init__(self, value):
        self.value = value

    def load(self):
        return self.value


class Probe:
    def __init__(self, changed=False):
        self.changed, self.requests, self.closed, self.accounts = changed, [], False, 0

    def set_cookie(self, key, value):
        assert key == 'wr_vid' and value == '7'

    def verify_account(self):
        self.accounts += 1

    def request(self, stage, url, body=None):
        self.requests.append((stage, url))
        if stage == 'shelf':
            assert url == check.BASE+'/web/shelf/sync' and body is None
            return {'books': [{'bookId': str(i)} for i in range(1, 6)]}
        assert stage in ('catalog_before', 'catalog_after')
        assert url == check.BASE+'/web/book/chapterInfos' and body == {'bookIds': [self.book_id]}
        value = 101 if self.changed and stage == 'catalog_after' else 100
        return {'bookId': self.book_id, 'updated': [
            {'chapterUid': 1, 'wordCount': value}, {'chapterUid': 2, 'wordCount': 200}, {}]}

    def close(self):
        self.closed = True


class Tests(unittest.TestCase):
    def setUp(self):
        self.saved = {'vid': '7', 'cookies': {'wr_vid': '7'}}
        self.probe = Probe()

    def test_bounded_read_only_projection(self):
        result = check.inspect(self.saved, Store(self.saved), lambda: self.probe)
        self.assertEqual((result['books'], result['normalized_rows'], result['normalization_omitted_rows']), (3, 6, 3))
        self.assertEqual(len(self.probe.requests), 7)
        self.assertEqual(self.probe.accounts, 2)
        self.assertTrue(self.probe.closed)
        self.assertNotIn('bookId', str(result))

    def test_changed_catalog_and_session_stop(self):
        self.probe.changed = True
        with self.assertRaises(ValueError):
            check.inspect(self.saved, Store(self.saved), lambda: self.probe)
        self.assertEqual(len(self.probe.requests), 3)
        self.assertTrue(self.probe.closed)
        self.probe = Probe()
        with self.assertRaises(ValueError):
            check.inspect(self.saved, Store({'vid': '8', 'cookies': {}}), lambda: self.probe)
        self.assertEqual(len(self.probe.requests), 1)
        self.assertTrue(self.probe.closed)

    def test_invalid_rows_and_weights(self):
        self.assertIsNone(check.weight(True))
        self.assertIsNone(check.weight(float('nan')))
        with self.assertRaises(ValueError):
            check.project([{'chapterUid': 1, 'wordCount': 1}, {'chapterUid': 1, 'wordCount': 1}])


if __name__ == '__main__':
    unittest.main()
