import hashlib
import unittest

from native_chapter_remote_reference import digest, image_url, search_token


class Response:
    def __init__(self, data, status=200):
        self.data, self.status = data, status

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        pass

    def read(self, limit):
        return self.data[:limit]


class Opener:
    def __init__(self, data, status=200):
        self.data, self.status, self.requests = data, status, []

    def open(self, request, timeout):
        self.requests.append(request)
        return Response(self.data, self.status)


class RemoteReferenceTests(unittest.TestCase):
    def test_search_token_stays_within_body(self):
        body = '<html><head><title>IgnoredTitle</title></head><body><p>这是一个合成测试的段落</p></body></html>'.encode()
        self.assertEqual(search_token(body), '这是一个合成测试的段落')
        with self.assertRaises(ValueError):
            search_token(b'<html><head><title>OnlyTitle</title></head><body></body></html>')

    def test_cookie_free_request_and_entity_normalization(self):
        image = b'\x89PNG\r\n\x1a\nsynthetic'
        opener = Opener(image)
        body = b'<img src="https://img.qq.com/x?a=1&amp;b=2">'
        self.assertEqual(digest(body, opener), hashlib.sha256(image).hexdigest())
        self.assertEqual(opener.requests[0].full_url, 'https://img.qq.com/x?a=1&b=2')
        self.assertNotIn('Cookie', opener.requests[0].headers)
        self.assertNotIn('Accesstoken', opener.requests[0].headers)

    def test_invalid_targets_and_responses(self):
        for url in ('http://img.qq.com/a', 'https://qq.com.evil.invalid/a', 'https://user@img.qq.com/a',
                    'https://127.0.0.1/a', 'https://img.qq.com:444/a', 'https://img.qq.com/a#fragment'):
            with self.subTest(url=url), self.assertRaises(ValueError):
                image_url(f'<img src="{url}">'.encode())
        body = b'<img src="https://img.qq.com/a">'
        for opener in (Opener(b'bad'), Opener(b'\x89PNG\r\n\x1a\n', 302), Opener(b'x' * (8*1024*1024+1))):
            with self.assertRaises(ValueError):
                digest(body, opener)


if __name__ == '__main__':
    unittest.main()
