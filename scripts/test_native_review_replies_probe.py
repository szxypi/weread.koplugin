#!/usr/bin/env python3
import contextlib
import io
import unittest
from unittest.mock import patch
from urllib.parse import urlencode

import verify_native_review_replies as probe
from verify_eink_login import BASE, NativeProbe


class ScopeTests(unittest.TestCase):
    def setUp(self):
        self.probe = probe.ScopedProbe()
        self.probe.books = {'42'}
        self.probe.review = 'review_1'
        self.list_query = dict(bookId='42', listType='3', listMode='1', synckey='0', count='61', maxIdx='0', tips='1')
        self.reply_query = dict(reviewId='review_1', commentsCount='21', commentsDirection='0', likesCount='0', synckey='0')

    def test_only_allowed_review_and_reply_reads_leave_scope(self):
        with patch.object(NativeProbe, 'request', return_value={}) as sent:
            self.probe.request('shelf', BASE + '/shelf/sync')
            self.probe.request('list', BASE + '/review/list?' + urlencode(self.list_query))
            self.probe.request('reply', BASE + '/review/single?' + urlencode(self.reply_query))
            self.probe.request('reply', BASE + '/review/single?' + urlencode(dict(self.reply_query, commentsCount='41')))
            self.assertEqual(sent.call_count, 4)
            for query in (dict(self.list_query, bookId='43'), dict(self.list_query, count='81'),
                          dict(self.list_query, mine='1'), dict(self.list_query, listType='11')):
                with self.assertRaises(ValueError):
                    self.probe.request('list', BASE + '/review/list?' + urlencode(query))
            for query in (dict(self.reply_query, reviewId='other'), dict(self.reply_query, commentsCount='22'),
                          dict(self.reply_query, commentsDirection='1'), dict(self.reply_query, extra='1')):
                with self.assertRaises(ValueError):
                    self.probe.request('reply', BASE + '/review/single?' + urlencode(query))
            with self.assertRaises(ValueError):
                self.probe.request('reply', BASE + '/review/single?' + urlencode(self.reply_query), body={})
            with self.assertRaises(ValueError):
                self.probe.request('reply', 'https://example.org/review/single?' + urlencode(self.reply_query))
            self.assertEqual(sent.call_count, 4)

    def test_default_is_offline(self):
        out = io.StringIO()
        with patch('sys.argv', ['script']), patch.object(probe.SessionStore, 'load', side_effect=AssertionError), \
                contextlib.redirect_stdout(out):
            self.assertEqual(probe.main(), 0)
        self.assertIn('OFFLINE_ONLY', out.getvalue())


if __name__ == '__main__':
    unittest.main()
