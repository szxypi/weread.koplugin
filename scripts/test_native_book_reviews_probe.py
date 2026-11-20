#!/usr/bin/env python3
import contextlib
import io
import unittest
from unittest.mock import patch
from urllib.parse import urlencode

import verify_native_book_reviews as probe
import verify_native_book_reviews_http as live
from verify_eink_login import BASE, NativeProbe


class ScopeTests(unittest.TestCase):
    def setUp(self):
        self.probe = probe.ScopedProbe()
        self.probe.ids = {'42'}
        self.query = dict(bookId='42', listType='3', listMode='1', synckey='0', count='21', maxIdx='0', tips='1')

    def request(self, query=None, stage='reviews', body=None, base=BASE, path='/review/list'):
        return self.probe.request(stage, base + path + '?' + urlencode(query or self.query), body=body)

    def test_only_scoped_read_requests_are_allowed(self):
        with patch.object(NativeProbe, 'request', return_value={'reviews': []}) as sent:
            self.request()
            self.request(dict(self.query, count='41'))
            self.probe.request('shelf', BASE + '/shelf/sync')
            self.assertEqual(sent.call_count, 3)
            for query in (dict(self.query, bookId='43'), dict(self.query, count='22'),
                          dict(self.query, listType='11'), dict(self.query, extra='x')):
                with self.assertRaises(ValueError):
                    self.request(query)
            for kw in ({'body': {}}, {'stage': 'other'}, {'base': 'http://i.weread.qq.com'},
                       {'base': 'https://example.org'}, {'path': '/review/delete'}):
                with self.assertRaises(ValueError):
                    self.request(**kw)
            self.assertEqual(sent.call_count, 3)

    def test_default_entry_points_do_not_access_session(self):
        for module in (probe, live):
            out = io.StringIO()
            with patch('sys.argv', ['script']), patch.object(module.SessionStore, 'load', side_effect=AssertionError), \
                    contextlib.redirect_stdout(out):
                self.assertEqual(module.main(), 0)
            self.assertIn('OFFLINE_ONLY', out.getvalue())


if __name__ == '__main__':
    unittest.main()
