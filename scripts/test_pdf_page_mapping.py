"""Original-page markers must occur exactly once and in document order."""
import unittest
from verify_pdf_page_mapping import MARKERS,MappingFullProbe,markers,ordered


class PDFMappingTest(unittest.TestCase):
    def test_one_chapter_and_split_chapters_preserve_page_order(self):
        source='<html><head><title>ignored</title></head><body>'+''.join('<p>'+v+'</p>' for v in MARKERS)+'</body></html>'
        self.assertTrue(ordered([markers(source)]))
        first='<body><p>'+MARKERS[0]+'</p><p>'+MARKERS[1]+'</p></body>'
        second='<body><p>'+MARKERS[2]+'</p><p>'+MARKERS[3]+'</p></body>'
        self.assertTrue(ordered([markers(first),markers(second)]))
        self.assertFalse(ordered([markers(second),markers(first)]))
    def test_missing_duplicate_and_hidden_markers_do_not_pass(self):
        source='<body>'+''.join('<p>'+v+'</p>' for v in MARKERS)+'</body>'
        for changed in (source.replace(MARKERS[3],''),source.replace('</body>','<p>'+MARKERS[0]+'</p></body>')):
            self.assertFalse(ordered([markers(changed)]))
        self.assertFalse(ordered([markers('<head>'+''.join(MARKERS)+'</head>')]))
        for bad in ([],[[1,2]],[[True,1,2,3]],[[0,1,2,3]]*5):self.assertFalse(ordered(bad))
    def test_inline_spans_preserve_the_text_without_invented_spaces(self):
        value=MARKERS[0];cut=len(value)//2
        self.assertEqual(markers('<p><span>'+value[:cut]+'</span><span>'+value[cut:]+'</span></p>')[0],0)
    def test_full_probe_checks_all_bounded_chapters_and_exact_target(self):
        from mock_weread import shards
        from test_cb_reading import FIRST,catalog,point,reader
        from test_web_source_progress import Opener
        first='<html><body><p>'+MARKERS[0]+'</p><p>'+MARKERS[1]+'</p></body></html>'
        second='<html><body><p>'+MARKERS[2]+'</p><p>'+MARKERS[3]+'</p></body></html>'
        values=[dict(books=[dict(bookId=FIRST)]),catalog(FIRST),point(FIRST),reader(FIRST,1),
            *[v.encode() for v in shards(first)],b'',reader(FIRST,2),*[v.encode() for v in shards(second)],b'',catalog(FIRST),point(FIRST)]
        probe=MappingFullProbe();probe.interval=0;probe.vid='900000';probe.authenticated=True
        probe.set_cookie('wr_vid','900000');probe.set_cookie('wr_skey','private-cookie');probe.opener=Opener(values)
        result=probe.prepare(1,expected_book_id=FIRST)
        self.assertEqual(result['book_id'],FIRST);self.assertEqual(probe.completed,2);self.assertTrue(ordered(probe.page_markers))


if __name__=='__main__':unittest.main()
