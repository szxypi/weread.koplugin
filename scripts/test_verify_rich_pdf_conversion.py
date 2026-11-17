"""Exercise privacy-preserving projections of PDF conversion evidence."""
import unittest
from unittest.mock import patch
from verify_rich_pdf_conversion import MARKERS,project,style_projection,summarize


class RichConversionTest(unittest.TestCase):
    def test_text_and_images_across_chapters(self):
        first=''.join('<p>'+s+'</p>' for s in MARKERS[:8])+'<img src="chapter-image.png">'
        second=''.join('<p>'+s+'</p>' for s in MARKERS[8:])+'<img src="chapter-image.png">'
        result=summarize([project(first),project(second)])
        self.assertTrue(result['all_text_markers_once'] and result['left_column_order_preserved']
                        and result['right_column_order_preserved'] and result['page_order_preserved'] and result['captions_present'])
        self.assertEqual((result['image_references'],result['converted_chapters_checked']),(2,2))
        self.assertNotIn('chapter-image.png',str(result))

    def test_alternative_forms_and_style_urls_are_counted_without_urls(self):
        sample=project('<p style="background:url(secret.png)">Text</p><svg></svg><canvas></canvas>'
                       '<style>.a{background:url(other.png)}</style>')
        with patch('verify_rich_pdf_conversion.decode_style_shard',return_value='.b{background:url(private.png)}'):
            style=style_projection('synthetic')
        sample['style_decoded']=style['decoded'];sample['style_url_functions']=style['url_functions']
        result=summarize([sample])
        self.assertEqual((result['embedded_form_elements'],result['inline_css_url_functions'],
                          result['style_shards_decoded'],result['style_shard_url_functions']),(2,2,1,1))
        self.assertNotIn('.png',str(result))
        with patch('verify_rich_pdf_conversion.decode_style_shard',side_effect=ValueError('private')):
            self.assertEqual(style_projection('bad'),{'decoded':False,'url_functions':0})

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
