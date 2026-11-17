"""Exercise privacy-preserving projections of PDF conversion evidence."""
import unittest
from verify_rich_pdf_conversion import MARKERS,project,summarize


class RichConversionTest(unittest.TestCase):
    def test_text_and_images_across_chapters(self):
        first=''.join('<p>'+s+'</p>' for s in MARKERS[:8])+'<img src="chapter-image.png">'
        second=''.join('<p>'+s+'</p>' for s in MARKERS[8:])+'<img src="chapter-image.png">'
        result=summarize([project(first),project(second)])
        self.assertTrue(result['all_text_markers_once'] and result['left_column_order_preserved']
                        and result['right_column_order_preserved'] and result['page_order_preserved'] and result['captions_present'])
        self.assertEqual((result['image_references'],result['converted_chapters_checked']),(2,2))
        self.assertNotIn('chapter-image.png',str(result))

    def test_missing_duplicate_reversed_and_malformed_do_not_pass(self):
        missing=project('<p>'+MARKERS[0]+'</p>')
        self.assertFalse(summarize([missing])['all_text_markers_once'])
        duplicate=project('<p>'+MARKERS[0]+'</p><p>'+MARKERS[0]+'</p>')
        self.assertFalse(summarize([duplicate])['page_order_preserved'])
        reversed_columns=project('<p>'+MARKERS[2]+'</p><p>'+MARKERS[1]+'</p>')
        self.assertFalse(summarize([reversed_columns])['left_column_order_preserved'])
        with self.assertRaises(ValueError):summarize([])
        with self.assertRaises(ValueError):summarize([{'counts':[], 'positions':[], 'image_references':0}])
        with self.assertRaises(ValueError):project('a'*(2*1024*1024+1))


if __name__=='__main__':unittest.main()
