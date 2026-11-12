"""Synthetic native discovery boundaries; no Keychain or upstream calls."""
from contextlib import redirect_stdout
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from verify_native_discovery import DiscoveryError,DiscoveryProbe,main,page


class DiscoveryTests(unittest.TestCase):
    def test_default_is_offline(self):
        with patch('verify_native_discovery.SessionStore') as web,patch('verify_native_discovery.NativeSessionStore') as native,\
                patch('verify_native_discovery.DiscoveryProbe') as probe,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main([]),0)
        web.assert_not_called();native.assert_not_called();probe.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_display_projection_and_cursor(self):
        value=page('search',dict(books=[dict(searchIdx=20,book=dict(bookInfo=dict(bookId='900001',title='Synthetic',token='private',version=70))),
                                       dict(searchIdx=21,bookInfo=dict(bookId='900001',title='Duplicate'))],hasMore=1))
        self.assertEqual(len(value['books']),1)
        self.assertEqual(value['next_cursor'],21)
        self.assertTrue(value['has_more'])
        self.assertNotIn('token',value['books'][0]);self.assertNotIn('version',value['books'][0])

    def test_malformed_and_error_responses(self):
        for value in (None,[],{},dict(books={}),dict(books=[False]),dict(books=[],errcode=-2012),dict(books=[],succ=0)):
            with self.subTest(value=value),self.assertRaises(DiscoveryError):page('search',value)
        with self.assertRaises(DiscoveryError):page('search',dict(books=[{}]*101))

    def test_no_progressing_cursor_or_invalid_session(self):
        with self.assertRaises(DiscoveryError):page('recommend',dict(books=[dict(bookId='900001',title='Synthetic')],hasMore=True),20)
        with self.assertRaises(DiscoveryError):page('similar',dict(booksimilar=dict(books=[],sessionId='bad\nvalue')))
        self.assertEqual(page('recommend',dict(books=[]))['books'],[])

    def test_guard_allows_only_known_gets(self):
        probe=DiscoveryProbe()
        probe.guard('search','https://i.weread.qq.com/store/search?keyword=%E4%B8%89%E4%BD%93&scope=10&count=20&maxIdx=0',None)
        probe.guard('similar','https://i.weread.qq.com/book/detailinfo?bookId=900001&listtypes=2&synckey=0&count=20&maxIdx=20&sessionId=s1',None)
        for stage,url,body in (
            ('search','http://i.weread.qq.com/store/search',None),('recommend','https://evil.invalid/book/recommend?maxIdx=0&count=20',None),
            ('recommend','https://i.weread.qq.com/book/recommend?maxIdx=0&count=20',{}),
            ('recommend','https://i.weread.qq.com/book/recommend?maxIdx=0&count=20&count=20',None),
            ('recommend','https://i.weread.qq.com/book/recommend?maxIdx=2147483648&count=20',None),
            ('recommend','https://i.weread.qq.com/book/recommend?maxIdx=0&count=20&extra=1',None),
            ('write','https://i.weread.qq.com/shelf/add?bookId=900001',None)):
            with self.subTest(url=url),self.assertRaises(DiscoveryError):probe.guard(stage,url,body)

    def test_saved_report_and_child_failure_do_not_echo_secrets(self):
        private='private-access-sentinel'
        native=dict(vid='88008800',accessToken=private)
        probe=SimpleNamespace(inspect=lambda _:dict(shelf_book_count=139,pages=[]),samples=[],target='99009900',report=dict(stages=[]))
        with patch('verify_native_discovery.SessionStore') as web,patch('verify_native_discovery.NativeSessionStore') as store,\
                patch('verify_native_discovery.DiscoveryProbe',return_value=probe),\
                patch('verify_native_discovery.subprocess.run',return_value=SimpleNamespace(returncode=1,stdout=private.encode())) as child,\
                redirect_stdout(io.StringIO()) as out:
            web.return_value.load.return_value=dict(vid='88008800')
            store.return_value.load.return_value=native
            self.assertEqual(main(['--saved-session','--native-http','--lua-command','synthetic']),1)
        self.assertIn(private,child.call_args.kwargs['input'].decode())
        self.assertEqual(native,{})
        for secret in (private,'88008800','99009900'):self.assertNotIn(secret,out.getvalue())
        self.assertEqual(json.loads(out.getvalue())['reason'],'lua_probe_failed')


if __name__=='__main__':unittest.main()
