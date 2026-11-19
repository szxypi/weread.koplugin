"""Offline scope and non-dispatch tests for the official viewport probe."""
from contextlib import redirect_stdout
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from cb_official_viewport import allowed,allowed_bookmark_read,compare_visible,observe
from fetch_weread_epub import reader_url_for,weread_e
import verify_cb_official_viewport as verify


class ViewportScopeTest(unittest.TestCase):
    def setUp(self):
        self.book='CB_Synthetic';self.chapters={'1','2'}
        self.shard=json.dumps(dict(b=weread_e(self.book),c=weread_e('1')))

    def test_only_selected_book_and_known_chapters_are_allowed(self):
        self.assertTrue(allowed('GET',reader_url_for(self.book),None,self.book,self.chapters))
        self.assertTrue(allowed('POST','https://weread.qq.com/web/book/chapter/e_0',self.shard,self.book,self.chapters))
        self.assertTrue(allowed('POST','https://weread.qq.com/web/book/chapterInfos',json.dumps(dict(bookIds=[self.book])),self.book,self.chapters))
        for method,url,body in [
            ('GET',reader_url_for('CB_Other'),None),
            ('GET','https://weread.qq.com/web/book/getProgress?bookId=CB_Other',None),
            ('GET','https://weread.qq.com/web/book/read?bookId=CB_Synthetic',None),
            ('POST','https://weread.qq.com/web/book/read',self.shard),
            ('POST','https://weread.qq.com/web/login/renewal','{}'),
            ('POST','https://weread.qq.com/web/book/chapter/e_0',json.dumps(dict(b=weread_e(self.book),c=weread_e('3')))),
            ('POST','https://weread.qq.com/web/book/chapter/e_0',json.dumps(dict(b=weread_e('CB_Other'),c=weread_e('1')))),
            ('POST','https://weread.qq.com/web/book/chapterInfos',json.dumps(dict(bookIds=[self.book,'CB_Other']))),
            ('GET','http://cdn.weread.qq.com/a',None),
            ('GET','https://attacker.invalid/a',None),
        ]:
            with self.subTest(url=url):self.assertFalse(allowed(method,url,body,self.book,self.chapters))

    def test_invalid_inputs_never_launch_browser(self):
        for book,chapters,cookies,offset in [('CB_bad/',{'1'},{'wr_vid':'1'},0),
                (self.book,{'bad'},{'wr_vid':'1'},0),(self.book,{'1'},{'unknown':'x'},0),
                (self.book,{'1'},{'wr_vid':'1'},-1)]:
            with self.assertRaises(ValueError):observe(book,chapters,cookies,offset)

    def test_bookmark_read_is_scoped_and_never_allows_a_write(self):
        base='https://weread.qq.com/web/book/bookmarklist?bookId=CB_Synthetic'
        self.assertTrue(allowed_bookmark_read('GET',base,None,self.book))
        self.assertTrue(allowed_bookmark_read('GET',base+'&syncKey=0',None,self.book))
        for method,url,body,book in [('POST',base,'{}',self.book),('GET',base,'{}',self.book),
                ('GET',base+'&syncKey=1',None,self.book),('GET',base+'&bookId=CB_Other',None,self.book),
                ('GET',base+'&extra=1',None,self.book),('GET',base+'#fragment',None,self.book),
                ('GET',base.replace('weread.qq.com','attacker.invalid'),None,self.book),
                ('GET',base.replace('https:','http:'),None,self.book),('GET',base,None,'CB_Other')]:
            with self.subTest(url=url):self.assertFalse(allowed_bookmark_read(method,url,body,book))

    def test_offline_default_does_not_read_credentials_or_launch_browser(self):
        with patch.object(verify,'SessionStore') as store,patch.object(verify,'observe') as browser,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(verify.main([]),0)
        store.assert_not_called();browser.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def test_ocr_passes_private_input_only_through_pipe_and_checks_result_shape(self):
        good=dict(result='OK',recognized_lines=2,matches=[dict(exact=False,windows=1),dict(exact=False,windows=0)])
        with patch('cb_official_viewport.subprocess.run',return_value=SimpleNamespace(returncode=0,stdout=json.dumps(good).encode())) as child:
            self.assertEqual(compare_visible(b'private-image',['private-anchor','other-control']),good)
        self.assertNotIn('private-anchor',' '.join(child.call_args.args[0]))
        self.assertEqual(json.loads(child.call_args.kwargs['input'])['anchors'][0],'private-anchor')
        for invalid in (dict(good,private='must not pass'),dict(good,matches=[dict(exact=True,windows='1')])):
            with patch('cb_official_viewport.subprocess.run',return_value=SimpleNamespace(returncode=0,stdout=json.dumps(invalid).encode())):
                with self.assertRaises(ValueError):compare_visible(b'image',['anchor'])

    def test_target_and_control_anchors_are_unique_and_separated(self):
        paragraphs=['<p>Paragraph %04d unique synthetic sentence with extra text.</p>'%i for i in range(80)]
        source='<html><body>'+''.join(paragraphs)+'</body></html>'
        from verify_source_coordinates import FilteredSource
        model=FilteredSource(source);index=len(model.starts)//3
        values,relation=verify.anchors_for(source,model.starts[index])
        self.assertEqual(relation,'exact')
        self.assertEqual(len(values),3);self.assertEqual(len(set(values)),3)
        values,relation=verify.anchors_for(source,1)
        self.assertEqual(relation,'following');self.assertTrue(values)
        self.assertEqual(verify.anchors_for(source,10**9),([],'unavailable'))


if __name__=='__main__':unittest.main()
