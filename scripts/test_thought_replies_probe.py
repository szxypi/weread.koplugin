#!/usr/bin/env python3
import contextlib
import io
import unittest
from unittest.mock import patch
from urllib.parse import urlencode

import verify_thought_replies as probe
from verify_eink_login import BASE, NativeProbe


class ScopeTests(unittest.TestCase):
    def test_only_selected_review_read_is_allowed(self):
        selected = probe.SingleProbe('synthetic_1')
        query = dict(reviewId='synthetic_1', commentsCount=21, commentsDirection=0, likesCount=0, synckey=0)
        with patch.object(NativeProbe, 'request', return_value={}) as sent:
            selected.request('single', BASE + '/review/single?' + urlencode(query))
            for change in (dict(reviewId='other'), dict(commentsCount=22), dict(commentsDirection=1), dict(extra=1)):
                bad = dict(query, **change)
                with self.assertRaises(ValueError):
                    selected.request('single', BASE + '/review/single?' + urlencode(bad))
            with self.assertRaises(ValueError):
                selected.request('single', BASE + '/review/single?' + urlencode(query), body={})
            with self.assertRaises(ValueError):
                selected.request('single', 'https://example.org/review/single?' + urlencode(query))
            self.assertEqual(sent.call_count, 1)

    def test_default_is_offline(self):
        out = io.StringIO()
        with patch('sys.argv', ['script']), patch.object(probe.SessionStore, 'load', side_effect=AssertionError), \
                contextlib.redirect_stdout(out):
            self.assertEqual(probe.main(), 0)
        self.assertIn('OFFLINE_ONLY', out.getvalue())


if __name__ == '__main__':
    unittest.main()
