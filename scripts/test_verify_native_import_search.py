import io
import json
import unittest
from contextlib import redirect_stdout
from urllib.parse import urlencode
from unittest.mock import patch

from verify_native_import_search import ScopedNativeSearch, main, shape


class Response:
    status = 200
    def __enter__(self): return self
    def __exit__(self, *_args): pass
    def read(self, _limit): return b'{"result": []}'


class Opener:
    def __init__(self): self.calls = 0
    def open(self, request, timeout):
        self.calls += 1
        assert request.get_method() == 'GET'
        return Response()


class NativeImportSearchTests(unittest.TestCase):
    def setUp(self):
        self.opener = Opener()
        self.probe = ScopedNativeSearch('CB_abc123', '关键词', self.opener)
        self.query = dict(bookId='CB_abc123', keyword='关键词', count=10, fragmentSize=150, maxIdx=0, onlyCount=0)
        self.url = 'https://i.weread.qq.com/book/search?' + urlencode(self.query)
        self.credentials = {'vid': '1', 'accessToken': 'token'}

    def test_only_exact_one_shot_get_is_allowed(self):
        for url, body in ((self.url.replace('i.weread.qq.com', 'other.example'), None),
                          (self.url.replace('count=10', 'count=11'), None),
                          (self.url, {})):
            with self.assertRaises(ValueError):
                self.probe.request('native_search', url, body=body, credentials=self.credentials)
        self.assertEqual(self.opener.calls, 0)
        self.probe.request('native_search', self.url, credentials=self.credentials)
        with self.assertRaises(ValueError):
            self.probe.request('native_search', self.url, credentials=self.credentials)
        self.assertEqual(self.opener.calls, 1)

    def test_projection_never_outputs_private_values(self):
        value = {'result': [{'chapterUid': 'secret chapter', 'abstract': 'secret keyword',
                             'posBegin': 12, 'posEnd': 15, 'untrusted': 'private'}]}
        observed = shape(value, 'secret chapter', 'keyword', (12, 15))
        self.assertTrue(observed['target_text_in_abstract'])
        self.assertTrue(observed['target_exact_coordinates'])
        self.assertNotIn('secret', json.dumps(observed))
        self.assertNotIn('private', json.dumps(observed))

    def test_default_does_not_load_sessions(self):
        with patch('verify_native_import_search.SessionStore', side_effect=AssertionError('opened')):
            with redirect_stdout(io.StringIO()): self.assertEqual(main([]), 0)


if __name__ == '__main__': unittest.main()
