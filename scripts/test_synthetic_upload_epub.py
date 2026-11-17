"""Validate the synthetic EPUB structure without touching account data."""
import io,unittest,xml.etree.ElementTree as ET,zipfile
from synthetic_upload_epub import FILES,TEXT,build


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


if __name__=='__main__':unittest.main()
