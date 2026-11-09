#!/usr/bin/env python3
"""Independent XML/ZIP checks for generated footnote definitions and references."""
from pathlib import Path
import tempfile
import unittest
import zipfile

from verify_book_footnotes import inspect_epub, lua_transform

REPO = Path(__file__).resolve().parent.parent


class FootnotePackageTests(unittest.TestCase):
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
