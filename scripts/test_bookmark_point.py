"""Bookmark scalar/UTF-16 units, exact source points and reverse mapping."""
import unittest
from bookmark_point import project,from_mark,point_range
from selection_quote import Selection


def coordinate(raw,needle):
    model=Selection(raw);at=model.flat.index(''.join(needle.split()))
    return model.filtered.starts[model.visible[at]]


class BookmarkPointTests(unittest.TestCase):
    def test_scalar_point_is_not_a_utf16_progress_offset(self):
        raw='<body><p>😀 Unique bookmark source text with sufficient context.</p></body>'
        co=coordinate(raw,'Unique');value=project(raw,co)
        self.assertEqual(int(value['range']),raw.index('Unique'));self.assertEqual(co,int(value['range'])+1)
        row=dict(type=0,chapterUid=2,range=value['range'])
        point=from_mark(raw,'41','2',row)
        self.assertEqual(point['chapter_offset'],co);self.assertFalse(point['upload_verified'])
        self.assertEqual(point['basis'],'filtered_xhtml_utf16')

    def test_leading_bom_is_excluded_only_from_server_raw_range(self):
        raw='<body><p>Unique bookmark source text with context.</p></body>'
        plain=project(raw,coordinate(raw,'Unique'));bom=project('\ufeff'+raw,coordinate('\ufeff'+raw,'Unique'))
        self.assertEqual(plain['range'],bom['range']);self.assertEqual(plain['chapter_offset']+1,bom['chapter_offset'])

    def test_ignored_tags_and_entities_do_not_shift_a_saved_point(self):
        raw='<body><p>Prefix<a href="https://example.invalid/">Unique &amp; 😀 bookmark text</a> suffix.</p></body>'
        co=coordinate(raw,'Unique');value=project(raw,co)
        self.assertGreater(int(value['range']),co);self.assertTrue(value['markText'].startswith('Unique & 😀 bookmark'))
        reverse=from_mark(raw,'41','2',dict(type=0,chapterUid=2,range=value['range']))
        self.assertEqual(reverse['chapter_offset'],co)

    def test_preview_has_complete_unicode_and_does_not_cross_its_quota(self):
        text='Unique '+('中文 😀 &amp; '*100);raw='<body><p>'+text+'</p></body>'
        value=project(raw,coordinate(raw,'Unique'))
        self.assertLessEqual(len(value['markText']),140);self.assertNotIn('&amp;',value['markText'])
        value['markText'].encode('utf-8',errors='strict')

    def test_invalid_or_nonvisible_raw_points_and_other_scopes_are_refused(self):
        raw='<html><head><title>Hidden title</title></head><body><p>Unique bookmark context.</p></body></html>'
        good=dict(type=0,chapterUid=2,range=str(raw.index('Unique')))
        for bad in (dict(good,type=1),dict(good,type=True),dict(good,bookId='42'),dict(good,chapterUid=3),dict(good,range='1-2'),dict(good,range='0'),dict(good,range=str(raw.index('Hidden'))),dict(good,range='9999999')):
            with self.subTest(bad=bad),self.assertRaises(ValueError):from_mark(raw,'41','2',bad)
        for bad in ('01','-1','1-1','1.0','2147483648',True,None):
            with self.subTest(bad=bad),self.assertRaises(ValueError):point_range(bad)

    def test_chapter_end_and_inside_entity_never_become_nearest_points(self):
        raw='<body><p>Unique &amp; bookmark context.</p></body>';model=Selection(raw)
        with self.assertRaises(ValueError):project(raw,model.filtered.ends[model.visible[-1]])
        with self.assertRaises(ValueError):from_mark(raw,'41','2',dict(type=0,chapterUid=2,range=str(raw.index('&amp;')+1)))

    def test_returned_preview_is_optional_but_present_text_must_match_source(self):
        raw='<body><p>Unique bookmark\r\nsource text with sufficient context.</p></body>'
        value=project(raw,coordinate(raw,'Unique'));self.assertIn('\r\n',value['markText'])
        row=dict(type=0,chapterUid=2,range=value['range'],markText=value['markText'])
        self.assertEqual(from_mark(raw,'41','2',row)['chapter_offset'],value['chapter_offset'])
        for preview in ('Another source',123,'\x00','\x7f','\ud800'):
            with self.subTest(preview=repr(preview)),self.assertRaises((ValueError,UnicodeError)):
                from_mark(raw,'41','2',dict(row,markText=preview))
        for preview in (None,''):
            self.assertEqual(from_mark(raw,'41','2',dict(row,markText=preview))['chapter_offset'],value['chapter_offset'])


if __name__=='__main__':unittest.main()
