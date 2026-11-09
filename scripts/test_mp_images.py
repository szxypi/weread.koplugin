import contextlib
import io
import json
import unittest
from unittest.mock import patch
from verify_mp_images import image_url,media,Images,main

class ImageTests(unittest.TestCase):
    def test_exact_anonymous_cdn_urls(self):
        self.assertEqual(image_url('//mmbiz.qpic.cn/x?a=1#fragment'),'https://mmbiz.qpic.cn/x?a=1')
        self.assertEqual(image_url('http://mmbiz.qlogo.cn/x'),'https://mmbiz.qlogo.cn/x')
        for value in ('https://mmbiz.qpic.cn:443/x','https://user@mmbiz.qpic.cn/x','https://mmbiz.qpic.cn.evil/x',
                      'https://mmbiz.qpic.cn/x\ny','file:///x','https://mmbiz.qpic.cn','https://mmbiz.qpic.cn/x y'):
            self.assertIsNone(image_url(value))
    def test_bitmap_signatures_only(self):
        for data,kind in ((b'\x89PNG\r\n\x1a\n','image/png'),(b'\xff\xd8\xff','image/jpeg'),
                          (b'GIF89a','image/gif'),(b'RIFFxxxxWEBP','image/webp')):
            self.assertEqual(media(data),kind)
        self.assertIsNone(media(b'<html>verification</html>'))
        self.assertIsNone(media(b'<svg/>'))
    def test_image_sources_deduplicate_and_decode(self):
        images=Images();images.feed('<img data-src="//mmbiz.qpic.cn/x?a=1&amp;b=2"><img src="https://mmbiz.qpic.cn/x?a=1&amp;b=2"><img src="file:///private">')
        self.assertEqual(images.urls,['https://mmbiz.qpic.cn/x?a=1&b=2'])
    def test_offline_never_opens_keychain(self):
        with patch('verify_mp_images.SessionStore',side_effect=AssertionError('Keychain')),contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main([]),0)
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

if __name__=='__main__':unittest.main()
