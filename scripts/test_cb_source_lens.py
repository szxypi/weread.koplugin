"""Source lens keeps raw and filtered offsets distinct, without snapping."""
import unittest
from cb_source_lens import compare,RawText
from verify_source_coordinates import FilteredSource,CoordinateError

RAW='<html><body><p>Beginning with ignored <a>inline link</a> then a unique synthetic phrase continuing here.</p></body></html>'
QUOTE='then a unique synthetic phrase'


class CbLensTests(unittest.TestCase):
    def test_raw_and_filtered_offsets_differ_after_removed_tags(self):
        a=RawText(RAW);b=FilteredSource(RAW);raw=a.locate(QUOTE)[0];filtered=b.locate(QUOTE)[0]
        self.assertNotEqual(raw,filtered)
        r=compare(RAW,raw,QUOTE);self.assertTrue(r['raw']['summary_at_offset']);self.assertFalse(r['filtered']['summary_at_offset'])
        r=compare(RAW,filtered,QUOTE);self.assertTrue(r['filtered']['summary_at_offset']);self.assertFalse(r['raw']['summary_at_offset'])
    def test_summary_end_and_containment_are_distinguished(self):
        model=RawText(RAW);first,last=model.locate(QUOTE)
        r=compare(RAW,last,QUOTE);self.assertTrue(r['raw']['offset_at_summary_end']);self.assertFalse(r['raw']['summary_contains_offset'])
        r=compare(RAW,first+2,QUOTE);self.assertTrue(r['raw']['summary_contains_offset']);self.assertFalse(r['raw']['summary_at_offset'])
    def test_multi_body_spans_entities_and_utf16_surrogates(self):
        raw='<html><body><p>First separate body.</p></body></html><html><body><p>第二段😀唯一文字 &amp; 后续测试字符 sufficient unique text.</p></body></html>'
        model=RawText(raw);co=model.locate('第二段😀唯一文字 & 后续测试字符')[0]
        r=compare(raw,co,'第二段😀唯一文字 &amp; 后续测试字符')
        self.assertTrue(r['raw']['decoded_summary_unique']);self.assertFalse(r['raw']['summary_unique']);self.assertEqual(model.bodies,2)
    def test_malformed_bodies_never_receive_a_raw_position(self):
        for raw in ('<html>no body</html>','<body><body>nested</body></body>','<body>unclosed','<body/>','</body>'):
            with self.assertRaises(CoordinateError):RawText(raw)
    def test_short_or_repeated_summary_does_not_claim_unique_location(self):
        raw='<body><p>Same repeated diagnostic phrase.</p><p>Same repeated diagnostic phrase.</p></body>'
        r=compare(raw,0,'Same repeated diagnostic phrase')
        self.assertFalse(r['raw']['summary_unique']);self.assertFalse(r['filtered']['summary_unique']);self.assertFalse(r['raw']['visible_boundary'])


if __name__=='__main__':unittest.main()
