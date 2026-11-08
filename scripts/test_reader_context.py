#!/usr/bin/env python3
"""Offline download-context identity and request-address regressions."""
import json
import unittest
from fetch_weread_epub import reader_url_for
from verify_reader_context import ContextError, book_id, identifier, project, request_url


class ReaderContextTest(unittest.TestCase):
    def setUp(self):
        self.book=dict(book_id='900001')
        self.url=reader_url_for('900001')
        self.reader=dict(bookInfo=dict(bookId='900001',title='Synthetic',author='Author'),psvts='synthetic-psvts',pclts=0,
                         token='synthetic-token',currentChapter=dict(chapterUid=2),progress=dict(book=dict(progress=10)))
    def html(self):
        return 'window.__INITIAL_STATE__='+json.dumps(dict(reader=self.reader))+';(function(){})();'
    def test_identity_aliases(self):
        self.assertEqual(book_id(dict(book_id='42',bookId=42)),'42')
        for row in ({},dict(book_id='42',bookId='43'),dict(book_id=False),dict(book_id='0'),dict(book_id='MP_WXS_123')):
            with self.subTest(row=row),self.assertRaises(ContextError): book_id(row)
    def test_ids_and_zero_chapter(self):
        self.assertEqual(identifier('a0b1c2'),'a0b1c2')
        self.assertEqual(identifier(0,chapter=True),'0')
        for value in ('01','../book','-1',' ',{},True,9007199254740992):
            with self.subTest(value=value),self.assertRaises(ContextError): identifier(value)
    def test_stale_urls_recover_to_current_book(self):
        for url in ('https://example.invalid/',reader_url_for('900002'),'http://weread.qq.com/web/reader/x',
                    self.url+'/extra','https://weread.qq.com:443'+self.url.split('.com')[1],self.url+'\n',{'bad':1}):
            with self.subTest(url=url): self.assertEqual(request_url(dict(self.book,reader_url=url)),self.url)
    def test_selected_chapter_and_sharing(self):
        chapter=reader_url_for('900001',2)
        self.assertEqual(request_url(dict(self.book,reader_url=chapter+'?wvid=discard#discard')),chapter)
        self.assertEqual(request_url(dict(self.book,reader_url=self.url),2),chapter)
        self.assertEqual(request_url(dict(self.book,reader_url=self.url.replace('https://weread.qq.com','HTTPS://WEREAD.QQ.COM'))),self.url)
    def test_same_book_valid_session_preserved(self):
        value=project(self.book,self.html())
        self.assertEqual(value['pclts'],0)
        self.assertEqual(value['psvts'],'synthetic-psvts')
        self.assertEqual(value['progress'],dict(progress=10))
    def test_wrong_book_rejected(self):
        self.reader['bookInfo']['bookId']='900002'
        with self.assertRaisesRegex(ContextError,'book_mismatch'): project(self.book,self.html())
    def test_optional_position_owner_checked(self):
        for key in ('currentChapter','progress'):
            self.setUp()
            row=self.reader[key]['book'] if key=='progress' else self.reader[key]
            row['bookId']='900002'
            with self.assertRaisesRegex(ContextError,'book_mismatch'): project(self.book,self.html())
    def test_regex_only_page_is_not_context(self):
        for html in ('<script>{"bookId":"900001","psvts":"synthetic"}</script>',self.html().replace('bookInfo','other'),self.html().replace('window.__INITIAL_STATE__','other')):
            with self.subTest(html=html),self.assertRaises(ContextError): project(self.book,html)
    def test_missing_and_bad_session(self):
        for field,value in [('psvts',None),('psvts',''),('psvts',123),('token','private\nvalue'),('token',{}),('pclts',True),('pclts',-1)]:
            self.setUp();self.reader[field]=value
            with self.subTest(field=field,value=value),self.assertRaises(ContextError): project(self.book,self.html())
    def test_omitted_session_fields_are_not_inherited(self):
        self.reader.pop('pclts');self.reader.pop('token')
        value=project(dict(self.book,token='old',pclts='old'),self.html())
        self.assertNotIn('pclts',value);self.assertNotIn('token',value)
    def test_bounded_html(self):
        with self.assertRaises(ContextError): project(self.book,'x'*(4*1024*1024+1))


if __name__=='__main__': unittest.main()
