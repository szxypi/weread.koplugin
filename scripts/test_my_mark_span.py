"""Exact source endpoints, full quotations, entities and conservative anchors."""
import hashlib
import unittest
from my_mark_span import project,verify_anchor
from selection_quote import Selection


def row(raw,text,marker=None):
    source=raw.removeprefix('\ufeff');a=source.index(text) if marker is None else None
    return dict(type=1,chapterUid=2,range=marker or f'{a}-{a+len(text)}',markText=text)


class SpanTests(unittest.TestCase):
    def test_plain_unicode_and_leading_bom(self):
        raw='<body><p>前言 😀Unique selected quote and following context.</p></body>'
        mark=row(raw,'Unique selected quote');result=project(raw,'41','2',mark)
        model=Selection(raw);at=model.flat.index('Unique')
        self.assertEqual(result['first'],model.filtered.starts[model.visible[at]])
        self.assertEqual(result['last'],model.filtered.ends[model.visible[at+len('Uniqueselectedquote')-1]])
        self.assertEqual(project('\ufeff'+raw,'41','2',mark)['first'],result['first']+1)
        self.assertEqual(result['normalized_sha256'],hashlib.sha256(b'Uniqueselectedquote').hexdigest())

    def test_entity_and_cross_paragraph_complete_range(self):
        raw='<body><p>Unique &amp; 😀 <b>selected</b></p><p>\nquote with context ending.</p></body>'
        a=raw.index('Unique');b=raw.index(' with')
        mark=row(raw,'Unique & 😀 selected\nquote',f'{a}-{b}')
        span=project(raw,'41','2',mark);model=Selection(raw)
        forward=model.project(span['first'],span['last'],mark['markText'])
        self.assertEqual(forward['range'],mark['range'])

    def test_edge_whitespace_is_trimmed_without_changing_internal_text(self):
        raw='<body><p>\n  Unique selected quote and following context. \t\n</p></body>'
        mark=row(raw,'Unique selected quote and following context.',f"{raw.index(chr(10))}-{raw.index('</p>')}")
        span=project(raw,'41','2',mark);self.assertGreater(span['first'],int(mark['range'].split('-')[0]))
        mark['markText']='Unique  selected quote and following context.'
        with self.assertRaises(ValueError):project(raw,'41','2',mark)

    def test_wrong_scope_partial_entity_and_out_of_source_refused(self):
        raw='<body><p>Unique &amp; selected quote.</p></body>';mark=row(raw,'Unique & selected quote.',f"9-{raw.index('</p>')}")
        for changed in (dict(mark,type=0),dict(mark,chapterUid=3),dict(mark,bookId='42'),dict(mark,range='9-999999'),dict(mark,range=f"{raw.index('&amp;')+1}-{raw.index('</p>')}") ):
            with self.subTest(changed=changed),self.assertRaises(ValueError):project(raw,'41','2',changed)

    def test_long_highlights_do_not_inherit_the_editor_4096_byte_limit(self):
        text='Beginning unique '+('long content '*400)+'unique ending.'
        raw='<body><p>'+text+'</p></body>';span=project(raw,'41','2',row(raw,text))
        self.assertGreater(span['normalized_bytes'],4096)

    def test_anchor_context_is_unique_and_pinpoints_the_expected_boundary(self):
        raw='<body><p>Unique selected quote and following context.</p></body>';mark=row(raw,'Unique selected quote')
        span=project(raw,'41','2',mark)
        anchor=dict(co=span['first'],basis='filtered_xhtml_utf16',point_unit='unicode_scalars',point_offset=0,text='Uniqueselectedquoteandfollowingcontext.')
        self.assertTrue(verify_anchor(raw,span['first'],anchor))
        with self.assertRaises(ValueError):verify_anchor(raw,span['first'],dict(anchor,point_offset=1))


if __name__=='__main__':unittest.main()
