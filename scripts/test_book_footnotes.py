#!/usr/bin/env python3
"""Independent XML/ZIP checks for generated footnote definitions and references."""
from pathlib import Path
import tempfile
import unittest
import zipfile

from verify_book_footnotes import inspect_epub, inspect_epub_links, lua_transform

REPO = Path(__file__).resolve().parent.parent


class FootnotePackageTests(unittest.TestCase):
    def inspect_links(self, bodies, assets=None):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'multiple.epub'
            with zipfile.ZipFile(path,'w') as archive:
                for name,body in bodies.items():
                    archive.writestr(name,'<html xmlns="http://www.w3.org/1999/xhtml"><body>'+body+'</body></html>')
                for name,data in (assets or {}).items():
                    archive.writestr(name,data)
            return inspect_epub_links(path)

    def test_multi_chapter_ids_are_scoped_and_return_links_resolve(self):
        result=self.inspect_links({
            'OEBPS/text/body.xhtml':'<a id="ref" href="notes.xhtml#n">[1]</a>',
            'OEBPS/text/notes.xhtml':'<aside id="n"><a href="body.xhtml#ref">返回</a>'
                                     '<a href="references.xhtml#ref">资料</a></aside><p id="ref">同名</p>',
            'OEBPS/text/references.xhtml':'<p id="ref">资料<a href="notes.xhtml#n">返回注释</a></p>'})
        self.assertEqual((result['chapters'],result['local_links'],result['broken_local_links'],result['duplicate_ids']), (3,4,0,0))

    def test_multi_chapter_missing_file_and_anchor_are_detected(self):
        result=self.inspect_links({'OEBPS/text/body.xhtml':'<a href="missing.xhtml#ref">错文件</a>'
                                                            '<a href="#missing">错锚点</a>'})
        self.assertEqual(result['broken_local_links'],2)

    def test_multi_chapter_duplicate_anchor_is_not_a_valid_target(self):
        result=self.inspect_links({'OEBPS/text/body.xhtml':'<a href="#ref">重复</a><p id="ref"/><p id="ref"/>'})
        self.assertEqual((result['duplicate_ids'],result['broken_local_links']),(1,1))

    def test_multi_chapter_unicode_percent_and_xml_entities(self):
        result=self.inspect_links({
            'OEBPS/text/body.xhtml':'<a href="%E8%B5%84%E6%96%99%20100%25.xhtml#%E6%9D%90%E6%96%99%26%E8%AF%B4%E6%98%8E">资料</a>',
            'OEBPS/text/资料 100%.xhtml':'<p id="材料&amp;说明">原文</p>'})
        self.assertEqual(result['broken_local_links'],0)

    def test_multi_chapter_file_only_link_is_valid(self):
        result=self.inspect_links({'OEBPS/text/body.xhtml':'<a href="notes.xhtml">章首</a>',
                                   'OEBPS/text/notes.xhtml':'<p>资料</p>'})
        self.assertEqual((result['file_only_links'],result['broken_local_links']),(1,0))

    def test_multi_chapter_external_links_need_no_fetch(self):
        result=self.inspect_links({'OEBPS/text/body.xhtml':'<a href="https://example.org#n">网页</a>'
                                   '<a href="mailto:reader@example.org">邮件</a><a href="//example.org#n">网页</a>'})
        self.assertEqual((result['external_links'],result['local_links']),(3,0))

    def test_multi_chapter_invalid_uri_and_archive_escape_are_detected(self):
        result=self.inspect_links({'OEBPS/text/body.xhtml':'<a href="#bad%zz">编码</a><a href="../../../out.xhtml">越界</a>'})
        self.assertEqual((result['invalid_local_links'],result['broken_local_links']),(2,2))

    def test_multi_chapter_local_images_are_checked_in_zip(self):
        result=self.inspect_links({'OEBPS/text/body.xhtml':'<img src="../images/valid.svg"/>'
                                   '<img src="../images/missing.svg"/><img src="data:image/png;base64,AA=="/>'},
                                  {'OEBPS/images/valid.svg':'<svg/>'})
        self.assertEqual((result['local_images'],result['missing_local_images']),(2,1))

    def inspect(self, html):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "synthetic.epub"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("OEBPS/text/chapter.xhtml", '<html xmlns="http://www.w3.org/1999/xhtml" '
                                 'xmlns:epub="http://www.idpf.org/2007/ops"><body>' + html + '</body></html>')
            return inspect_epub(path)

    def test_shared_target_from_lua_has_one_definition_and_all_returns(self):
        source = ('<p><a id="ref-a" epub:type="noteref" href="#note">[1]</a>'
                  '<a id="ref-b" epub:type="noteref" href="#note">[1]</a></p>'
                  '<aside id="note" epub:type="footnote"><p>唯一脚注正文</p></aside>')
        transformed, _css, stats = lua_transform(REPO, source, {"chapterUid": 17})
        result = self.inspect(transformed)
        self.assertEqual(stats["converted"], 2)
        self.assertEqual(transformed.count("唯一脚注正文"), 1)
        self.assertEqual((result["noterefs"], result["generated_footnotes"], result["distinct_generated_targets"]), (2, 1, 1))
        for key in ("duplicate_ids", "broken_targets", "broken_backlinks", "broken_local_links",
                    "unreferenced_generated_notes", "missing_generated_backlinks"):
            self.assertEqual(result[key], 0, key)

    def test_missing_return_to_second_reference_is_detected(self):
        result = self.inspect('<a id="one" epub:type="noteref" href="#wrfn-x">[1]</a>'
                              '<a id="two" epub:type="noteref" href="#wrfn-x">[1]</a>'
                              '<aside id="wrfn-x" class="wr-book-footnote" epub:type="footnote">'
                              '<a href="#one">返回</a>正文</aside>')
        self.assertEqual(result["missing_generated_backlinks"], 1)

    def test_unreferenced_generated_note_is_detected(self):
        result = self.inspect('<aside id="wrfn-x" class="wr-book-footnote" epub:type="footnote">正文</aside>')
        self.assertEqual(result["unreferenced_generated_notes"], 1)

    def test_duplicate_ids_are_detected(self):
        self.assertEqual(self.inspect('<span id="same"/><span id="same"/>')["duplicate_ids"], 1)

    def test_broken_original_alias_is_detected(self):
        self.assertEqual(self.inspect('<a href="#old-note">查看</a>')["broken_local_links"], 1)

    def test_native_rich_note_retains_original_markup_and_target(self):
        source = ('<p><a epub:type="noteref" href="#rich">[1]</a></p>'
                  '<aside id="rich" epub:type="footnote">图注<img src="note.png" alt="注图"/></aside>')
        transformed, _css, stats = lua_transform(REPO, source, {"chapterUid": 17})
        self.assertEqual(transformed, source)
        self.assertEqual(stats["converted"], 0)
        result = self.inspect(transformed)
        self.assertEqual((result["footnotes"], result["generated_footnotes"], result["broken_targets"]), (1, 0, 0))

    def test_unreferenced_publisher_note_is_not_a_generated_orphan(self):
        result = self.inspect('<aside id="publisher-note" epub:type="footnote">原文注释</aside>')
        self.assertEqual((result["footnotes"], result["unreferenced_generated_notes"]), (1, 0))


if __name__ == "__main__":
    unittest.main()
