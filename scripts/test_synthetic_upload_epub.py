"""Validate the synthetic EPUB structure without touching account data."""
import io,unittest,xml.etree.ElementTree as ET,zipfile
from synthetic_upload_epub import FILES,TEXT,build,build_large,build_reading


class SyntheticEpubTest(unittest.TestCase):
    def test_reproducible_safe_epub_has_complete_navigation_and_original_text(self):
        raw=build();self.assertEqual(raw,build());self.assertTrue(1024<len(raw)<32768)
        with zipfile.ZipFile(io.BytesIO(raw)) as archive:
            self.assertEqual(archive.namelist(),list(FILES));self.assertIsNone(archive.testzip())
            self.assertEqual(archive.infolist()[0].filename,'mimetype');self.assertEqual(archive.infolist()[0].compress_type,zipfile.ZIP_STORED)
            for name,value in FILES.items():self.assertEqual(archive.read(name),value)
            for name in list(FILES)[1:]:ET.fromstring(archive.read(name))
            self.assertIn(TEXT.encode(),archive.read('EPUB/chapter.xhtml'))
            self.assertIn(b'href="chapter.xhtml"',archive.read('EPUB/nav.xhtml'))
    def test_large_epub_is_valid_and_preserves_the_same_readable_chapter(self):
        raw=build_large();self.assertGreater(len(raw),8*1024*1024);self.assertLess(len(raw),10*1024*1024)
        with zipfile.ZipFile(io.BytesIO(raw)) as archive:
            self.assertIsNone(archive.testzip());self.assertEqual(archive.read('EPUB/chapter.xhtml'),FILES['EPUB/chapter.xhtml'])
            self.assertEqual(len(archive.read('EPUB/padding.txt')),9*1024*1024)
            self.assertIn(b'href="padding.txt"',archive.read('EPUB/package.opf'))
            ET.fromstring(archive.read('EPUB/package.opf'))
    def test_reading_epub_has_unique_self_authored_passages(self):
        raw=build_reading();self.assertEqual(raw,build_reading())
        with zipfile.ZipFile(io.BytesIO(raw)) as archive:
            self.assertIsNone(archive.testzip());chapter=archive.read('EPUB/chapter.xhtml');ET.fromstring(chapter)
            self.assertEqual(chapter.count(TEXT.encode()),1)
            for index in range(1,49):self.assertEqual(chapter.count(f'Passage {index:02d} has an individual opening'.encode()),1)


if __name__=='__main__':unittest.main()
