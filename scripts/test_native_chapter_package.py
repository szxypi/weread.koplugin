import base64
import io
import json
import unittest
import zipfile
from urllib.parse import parse_qs, urlsplit

from native_chapter_package import PackageError, password, read
from verify_eink_login import BASE, ProbeError
from verify_native_chapter_package import ChapterProbe

ENCRYPTED = ('UEsDBAoACQAAABGcdl0tZn/dHAAAABAAAAAHABwAMzcuaHRtbFVUCQAD0tICa9LSAmt1eAsAAQT1AQAABBQAAACobNqDWeLYRHzMh9XMYW7BvSC3szjIDVOPX7UFUEsHCC1mf90cAAAAEAAAAFBLAQIeAwoACQAAABGcdl0tZn/dHAAAABAAAAAHABgAAAAAAAEAAACkgQAAAAAzNy5odG1sVVQFAAPS0gJrdXgLAAEE9QEAAAQUAAAAUEsFBgAAAAABAAEATQAAAG0AAAAAAA==')


def archive(rows):
    output = io.BytesIO()
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as z:
        for name, data in rows:
            z.writestr(name, data)
    return output.getvalue()


class NativeChapterPackageTests(unittest.TestCase):
    def test_envelope_and_real_zipcrypto(self):
        secret = password('vwSvXMONEDngLYTAXw3olg==', '12345678')
        self.assertEqual(secret, b'test-password')
        result = read(base64.b64decode(ENCRYPTED), secret, '37')
        self.assertEqual(result['source'], b'<p>Synthetic</p>')
        self.assertEqual(result['encrypted_entries'], 1)
        with self.assertRaises(PackageError):
            read(base64.b64decode(ENCRYPTED), b'wrong-password', '37')
        with self.assertRaises(PackageError):
            password('vwSvXMONEDngLYTAXw3olg==', '87654321')

    def test_manifest_preserves_order_and_chapter_identity(self):
        info = {'chapters': [{'chapterUid': 37, 'files': ['second.html', 'first.html']}]}
        data = archive([('info.txt', json.dumps(info)), ('first.html', 'first'), ('second.html', 'second'), ('0.css', 'style')])
        result = read(data, b'not-used', '37')
        self.assertEqual(result['source'], b'second\nfirst')
        self.assertTrue(result['html'])
        self.assertEqual(result['body_parts'], 2)
        with self.assertRaises(PackageError):
            read(data, b'not-used', '38')
        for filenames in (['first.html', 'first.html'], ['missing.html']):
            invalid = archive([('info.txt', json.dumps({'chapters': [{'chapterUid': 37, 'files': filenames}]})),
                               ('first.html', 'first')])
            with self.assertRaises(PackageError):
                read(invalid, b'not-used', '37')
        duplicate = archive([('info.txt', '{"chapters":[],"chapters":[]}'), ('37.html', 'first')])
        with self.assertRaises(PackageError):
            read(duplicate, b'not-used', '37')
        huge = archive([('info.txt', '{"chapters":[{"chapterUid":9007199254740992,"files":["37.html"]}]}'),
                        ('37.html', 'first')])
        with self.assertRaises(PackageError):
            read(huge, b'not-used', '37')

    def test_reject_ambiguous_or_unsafe_archives(self):
        for rows in ([('../37.html', 'bad')], [('1.html', 'a'), ('2.html', 'b')],
                     [('info.txt', '{'), ('37.html', 'a')], [('37.html', '')]):
            with self.subTest(rows=rows), self.assertRaises(PackageError):
                read(archive(rows), b'unused', '37')
        with self.assertRaises(PackageError):
            read(b'not a zip archive', b'unused', '37')
        with self.assertRaises(PackageError):
            password('not base64!', '12345678')

    def test_shared_parent_image_is_kept_in_memory_with_safe_name(self):
        image = b'\x89PNG\r\n\x1a\nsynthetic'
        data = archive([('37.html', '<p>Text</p>'), ('../images/shared.png', image)])
        result = read(data, b'unused', '37')
        self.assertEqual(result['source'], b'<p>Text</p>')
        self.assertEqual(result['parent_resources'], 1)
        self.assertEqual(result['assets'][0]['data'], image)
        self.assertEqual(result['assets'][0]['href'], 'images/native-1.png')
        self.assertTrue(result['image_signatures_recognized'])
        invalid = read(archive([('37.html', 'ok'), ('ignored.png', 'not an image')]), b'unused', '37')
        self.assertFalse(invalid['image_signatures_recognized'])
        self.assertEqual(invalid['unusable_resources'], 1)
        unsupported = read(archive([('37.html', 'ok'), ('diagram.svg', '<svg/>')]), b'unused', '37')
        self.assertFalse(unsupported['image_signatures_recognized'])
        self.assertEqual(unsupported['unusable_resources'], 1)
        with self.assertRaises(PackageError):
            read(archive([('37.html', 'ok'), ('../outside.txt', 'bad')]), b'unused', '37')

    def test_download_requires_explicit_entitlement_and_no_auto_purchase(self):
        class FixtureProbe(ChapterProbe):
            def __init__(self, chapter):
                super().__init__()
                self.chapter = chapter
                self.downloads = []

            def request(self, stage, url, body=None, credentials=None, timeout=15):
                self.guard(stage, url, body)
                if stage == 'shelf':
                    return {'books': [{'bookId': '42'}]}
                if stage == 'book':
                    return {'bookId': '42', 'format': 'epub', 'version': 1}
                return {'data': [{'bookId': '42', 'book': {'bookId': '42', 'format': 'epub', 'version': 1},
                                  'updated': [self.chapter]}]}

            def download(self, url, credentials):
                self.downloads.append(url)
                return base64.b64decode(ENCRYPTED), 'vwSvXMONEDngLYTAXw3olg=='

        credentials = {'vid': '12345678', 'accessToken': 'synthetic'}
        valid = FixtureProbe({'chapterUid': 37, 'wordCount': 250, 'price': 0})
        sample, chapter, decoded = valid.inspect(credentials)
        self.assertEqual((sample['book_id'], chapter['uid'], decoded['source']), ('42', 37, b'<p>Synthetic</p>'))
        query = parse_qs(urlsplit(valid.downloads[0]).query, keep_blank_values=True)
        self.assertEqual(query['chapters'], ['0,37'])
        self.assertEqual(query['stopAutoPayWhenBNE'], ['1'])
        self.assertEqual(query['preview'], ['0'])
        for candidate in ({'chapterUid': 37, 'wordCount': 250},
                          {'chapterUid': 37, 'wordCount': 250, 'price': 10, 'paid': 0}):
            probe = FixtureProbe(candidate)
            with self.assertRaises(ProbeError):
                probe.inspect(credentials)
            self.assertEqual(probe.downloads, [])

    def test_request_scope_is_fixed(self):
        probe = ChapterProbe()
        probe.allowed = {'42'}
        probe.guard('shelf', BASE + '/shelf/sync', None)
        with self.assertRaises(ProbeError):
            probe.guard('book', BASE + '/book/info?bookId=43', None)
        with self.assertRaises(ProbeError):
            probe.guard('shelf', BASE + '/shelf/delete', {'bookIds': ['42']})
        with self.assertRaises(ProbeError):
            probe.download(BASE + '/book/chapterdownload', {'vid': '12345678', 'accessToken': 'synthetic'})


if __name__ == '__main__':
    unittest.main()
