"""Raw rune coordinate reference boundaries, independent of Lua scanning."""
import unittest
from annotation_source_quotes import SourceQuotes


class SourceQuoteTests(unittest.TestCase):
    def test_unicode_runes_and_tags_keep_original_offsets(self):
        raw='<body><p>甲😀<b>乙</b>丙</p></body>'
        source=SourceQuotes(raw)
        first=raw.index('甲');last=raw.index('丙')+1
        self.assertEqual(source.quote(f'{first}-{last}'),'甲😀乙丙')
        self.assertEqual(source.quote(f'{first+1}-{first+2}'),'😀')

    def test_entities_require_complete_source_boundaries(self):
        raw='<p>A&amp;B&#x1F600;C</p>';source=SourceQuotes(raw)
        self.assertEqual(source.quote(f'{raw.index("A")}-{raw.index("C")+1}'),'A&B😀C')
        start=raw.index('&amp;')
        for first,last in ((start+1,start+5),(start,start+4)):
            self.assertEqual(source.quote(f'{first}-{last}'),'')

    def test_bom_crlf_quotes_in_tags_and_hidden_text(self):
        raw='<p title="a > b">前\r\n后</p><script>hidden</script><style>hidden</style><p>尾</p>'
        source=SourceQuotes('\ufeff'+raw)
        self.assertEqual(source.quote(f'{raw.index("前")}-{raw.index("尾")+1}'),'前\r\n后尾')

    def test_ranges_and_source_are_bounded(self):
        source=SourceQuotes('<p>abc</p>')
        for marker in ('x','1-1','9-2','0-100','-1-4'): self.assertEqual(source.quote(marker),'')
        for raw in ('',None,'a'*(2*1024*1024+1)):
            with self.assertRaises(ValueError):SourceQuotes(raw)

    def test_digest_is_order_independent_and_text_sensitive(self):
        source=SourceQuotes('<p>abc</p>')
        self.assertEqual(source.digest(['3-4','4-6']),source.digest(['4-6','3-4']))
        self.assertNotEqual(source.digest(['3-4']),SourceQuotes('<p>xyz</p>').digest(['3-4']))


if __name__ == '__main__': unittest.main()
