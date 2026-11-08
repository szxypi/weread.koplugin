#!/usr/bin/env python3
"""Offline source-coordinate checks; never loads a browser or account."""
import io
import json
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

from verify_source_coordinates import (CoordinateError, MAX_SOURCE_BYTES, PublicProbe, SourceText,
                                       boundaries, check_parser_rows, from_co, main)


class SourceCoordinateTests(unittest.TestCase):
    def test_utf16_boundaries_include_markup_bom_and_astral_scalars(self):
        raw, offsets = boundaries('\ufeff<p>甲😀乙</p>')
        at = raw.index('😀')
        self.assertEqual(offsets[at], at)
        self.assertEqual(offsets[at + 1], at + 2)
        self.assertEqual(offsets[0], 0)
        for i, co in enumerate(offsets):
            self.assertEqual(from_co(offsets, co), i)
        with self.assertRaises(CoordinateError):
            from_co(offsets, offsets[at] + 1)

    def test_invalid_offsets_or_source_rejected(self):
        for value in (-1, 0.5, float('nan'), '1', True, 999):
            with self.assertRaises(CoordinateError):
                from_co([0, 1, 3], value)
        for value in (None, '\ud800', 'x' * (MAX_SOURCE_BYTES + 1)):
            with self.assertRaises(CoordinateError):
                boundaries(value)

    def test_visible_source_excludes_head_comments_and_suppressed_tags(self):
        raw = '<html><head><title>不在正文</title><style>隐藏样式</style><script>隐藏脚本</script></head><body><!--注释--><p title="a > b">可见正文</p><p>后文</p></body></html>'
        source = SourceText(raw)
        self.assertEqual(''.join(source.characters), '可见正文后文')
        self.assertEqual(source.starts[0], raw.index('可见正文'))

    def test_sanitizer_changing_body_tags_or_incomplete_sources_are_rejected(self):
        for body in ('<script>hidden</script>', '<style>p{}</style>', '<unknown>正文</unknown>', '<a>链接正文</a>'):
            with self.assertRaises(CoordinateError):
                SourceText('<html><body>' + body + '</body></html>')
        for raw in ('<p>没有正文容器</p>', '<html><body><p>不完整</p>', '<body></body><body></body>'):
            with self.assertRaises(CoordinateError):
                SourceText(raw)

    def test_entities_map_to_raw_span_and_markup_affects_coordinates(self):
        raw = '<html><body><p>完整起始正文&amp;后半段正文&#x1F600;。</p></body></html>'
        source = SourceText(raw)
        first, last = source.locate('完整起始正文&后半段正文😀。')
        self.assertEqual(first, raw.index('完整起始正文'))
        self.assertEqual(last, raw.index('</p>'))
        amp = source.characters.index('&')
        self.assertEqual(source.ends[amp] - source.starts[amp], 5)

    def test_whitespace_and_entities_do_not_replace_original_coordinates(self):
        raw = '<html><body><p>这是一段\r\n需要精确定位的&nbsp;正文与尾声。</p></body></html>'
        first, _last = SourceText(raw).locate('这是一段需要精确定位的正文与尾声。')
        self.assertEqual(first, raw.index('这是一段'))

    def test_duplicate_and_overlapping_anchors_rejected(self):
        for text in ('x' * 20, '同样的正文需要精确定位。' * 2):
            source = SourceText('<html><body><p>' + text + '</p></body></html>')
            with self.assertRaises(CoordinateError):
                source.locate(text[:12])

    def test_context_disambiguates_without_fuzzy_matching(self):
        anchor = '同样的正文需要精确定位。'
        raw = '<html><body><p>左边' + anchor + '第一处</p><p>右边' + anchor + '第二处</p></body></html>'
        source = SourceText(raw)
        start, _end = source.locate(anchor, before='右边', after='第二处')
        self.assertEqual(start, raw.rindex(anchor))
        for needle in ('短句', anchor.replace('正文', '文章')):
            with self.assertRaises(CoordinateError):
                source.locate(needle)

    def test_official_parser_comparison_handles_entities_and_surrogate_halves(self):
        raw = '<p>甲😀乙&amp;丙</p>'
        emoji = raw.index('😀')
        _raw, offsets = boundaries(raw)
        rows = [dict(co=offsets[emoji], text='\ud83d'), dict(co=offsets[emoji] + 1, text='\ude00'),
                dict(co=offsets[raw.index('&')], text='&')]
        self.assertEqual(check_parser_rows(raw, rows), 3)
        with self.assertRaises(CoordinateError):
            check_parser_rows(raw, [dict(co=offsets[emoji] + 1, text='乙')])
        with self.assertRaises(CoordinateError):
            check_parser_rows(raw, [])

    def test_public_probe_cannot_access_login_progress_or_redirect_origins(self):
        opener = unittest.mock.Mock()
        probe = PublicProbe(opener)
        for url, body in (('https://weread.qq.com/web/book/read', {}),
                          ('https://weread.qq.com/web/login/renewal', {}),
                          ('https://other.example/web/book/chapter/e_0', {}),
                          ('https://weread.qq.com/web/reader/abc?token=private', None)):
            with self.assertRaises(CoordinateError):
                probe.request(url, body)
        opener.open.assert_not_called()

    def test_official_split_surrogate_glyphs_are_recorded_and_not_generalized(self):
        raw, offsets = boundaries('<p>😀。</p>')
        co = offsets[raw.index('😀')]
        stats = {}
        self.assertEqual(check_parser_rows(raw, [dict(co=co, text='\ufffd'), dict(co=co + 1, text='\ufffd')], stats), 2)
        self.assertEqual(stats['surrogate_replacement_nodes'], 2)
        with self.assertRaises(CoordinateError):
            check_parser_rows(raw, [dict(co=co + 2, text='\ufffd')])

    def test_literal_numeric_entities_preserve_raw_positions(self):
        raw = '<p>&#x1F600;后文</p>'
        stats = {}
        self.assertEqual(check_parser_rows(raw, [dict(co=3, text='&'), dict(co=4, text='#')], stats), 2)
        self.assertEqual(stats['literal_entity_nodes'], 1)

    def test_default_cli_is_offline_and_metadata_only(self):
        out = io.StringIO()
        with patch('sys.argv', ['verify_source_coordinates.py']), patch.object(PublicProbe, 'fetch') as fetch:
            with redirect_stdout(out), self.assertRaises(SystemExit) as exited:
                main()
        self.assertEqual(exited.exception.code, 0)
        fetch.assert_not_called()
        report = json.loads(out.getvalue())
        self.assertEqual(report['result'], 'OFFLINE_ONLY')
        self.assertEqual(report['network_requests'], 0)
        self.assertNotIn('source', report)


if __name__ == '__main__':
    unittest.main()
