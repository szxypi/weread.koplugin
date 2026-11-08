#!/usr/bin/env python3
"""Offline tests for Reader-link validation. No credentials or network."""
import contextlib
import io
import json
import unittest
from unittest.mock import patch
import verify_reader_link as link
from fetch_weread_epub import reader_url_for, weread_e


class ReaderLinkTests(unittest.TestCase):
    def setUp(self):
        self.url=reader_url_for('900001')
        self.source=dict(bookId='900001',title='Synthetic 中文',author='Author',token='private',progress=88,bookVersion=7)
        self.html='window.__INITIAL_STATE__='+json.dumps(dict(reader=dict(bookInfo=self.source)))+';(function(){})();'

    def test_normalize_share(self):
        self.assertEqual(link.canonical(' '+self.url+'k'+weread_e('2')+'?wvid=discarded#discarded\n'),self.url)
        self.assertEqual(link.canonical(self.url.replace('https://weread.qq.com','HTTPS://WEREAD.QQ.COM')),self.url)

    def test_reject_outside_scope(self):
        for value in [self.url.replace('https:','http:'),self.url.replace('weread.qq.com','weread.qq.com.evil.test'),
                      self.url.replace('weread.qq.com','user@weread.qq.com'),self.url.replace('weread.qq.com','weread.qq.com:443'),
                      self.url.replace('/web/reader/','/web/mp/reader/'),self.url+'/extra',self.url+'\nhttps://evil.test',
                      self.url.replace('/web/reader/','/web/reader/%2e%2e/'),self.url+'kbad',None,'x'*4097]:
            with self.subTest(kind=type(value).__name__),self.assertRaises((link.LinkError,ValueError)):link.canonical(value)

    def test_metadata_whitelist(self):
        result=link.project(self.url+'?wvid=discarded',self.html)
        self.assertEqual(result,dict(reader_url=self.url,metadata=dict(bookId='900001',title='Synthetic 中文',author='Author')))

    def test_identity_must_match_link(self):
        with self.assertRaises(link.LinkError):link.project(reader_url_for('900002'),self.html)

    def test_no_regex_fallback(self):
        with self.assertRaises(link.LinkError):link.project(self.url,'{"bookId":"900001","title":"Pretend"}')

    def test_bounded_content(self):
        with self.assertRaises(link.LinkError):link.project(self.url,'x'*(4*1024*1024+1))

    def test_missing_metadata(self):
        for body in ['{}','{"reader":{}}','{"reader":{"bookInfo":{"bookId":"900001"}}}']:
            with self.assertRaises(link.LinkError):link.project(self.url,'window.__INITIAL_STATE__='+body+';(function(){});')

    def test_offline_default(self):
        output=io.StringIO()
        with patch.object(link,'SessionStore',side_effect=AssertionError('keychain used')),patch.object(link,'WebSourceProbe',side_effect=AssertionError('network used')),contextlib.redirect_stdout(output):
            self.assertEqual(link.main([]),0)
        self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')


if __name__=='__main__':unittest.main()
