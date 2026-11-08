from contextlib import contextmanager
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from source_parser_preflight import MAX_PRIVATE_BYTES, PUBLIC_READER, verify_source
from verify_source_coordinates import CoordinateError

RAW='<html><body><p>只在内存核对的独特原文内容。</p></body></html>'


class SourceParserPreflightTests(unittest.TestCase):
    def browser(self, cookies=None, fail=False):
        state=SimpleNamespace(offline=False,closed=False,socket_blocked=False,routes=[],private_evaluated=False)
        def evaluate(_script,sources):
            self.assertTrue(state.offline)
            self.assertTrue(state.socket_blocked)
            self.assertEqual(sources,[RAW])
            state.private_evaluated=True
            if fail:raise RuntimeError('private-source-must-not-appear')
            return [[dict(co=RAW.index('只'),text='只')]]
        page=SimpleNamespace(goto=lambda url,**_kw: self.assertEqual(url,PUBLIC_READER),
                             set_default_timeout=lambda _timeout: None,evaluate=evaluate)
        def close():state.closed=True
        def socket(_pattern,callback):
            callback(SimpleNamespace(close=lambda: setattr(state,'socket_blocked',True)))
        context=SimpleNamespace(route=lambda _pattern,callback: state.routes.append(callback),
                                route_web_socket=socket,add_init_script=lambda _script: None,new_page=lambda: page,
                                set_offline=lambda value: setattr(state,'offline',value),cookies=lambda: cookies or [],close=close)
        browser=SimpleNamespace(new_context=lambda **_kw: context,close=lambda: None,version='synthetic-version')
        @contextmanager
        def playwright():
            yield SimpleNamespace(chromium=SimpleNamespace(launch=lambda **_kw: browser))
        return state,SimpleNamespace(sync_playwright=playwright)

    def test_private_text_is_supplied_after_network_is_disabled(self):
        state,module=self.browser()
        with patch.dict('sys.modules',{'playwright.sync_api':module}):
            result=verify_source(RAW,RAW.index('只'))
        self.assertTrue(result['official_parser_target_present'])
        self.assertTrue(state.private_evaluated and state.closed)
        self.assertNotIn(RAW,str(result))
        calls=[]
        state.routes[-1](SimpleNamespace(abort=lambda: calls.append('blocked')))
        self.assertEqual(calls,['blocked'])

    def test_unexpected_authenticated_browser_never_receives_private_text(self):
        state,module=self.browser(cookies=[dict(name='wr_skey')])
        with patch.dict('sys.modules',{'playwright.sync_api':module}),self.assertRaises(CoordinateError):
            verify_source(RAW,15)
        self.assertFalse(state.private_evaluated)
        self.assertTrue(state.closed)

    def test_errors_do_not_expose_source_and_browser_is_closed(self):
        state,module=self.browser(fail=True)
        with patch.dict('sys.modules',{'playwright.sync_api':module}),self.assertRaises(CoordinateError) as error:
            verify_source(RAW,15)
        self.assertNotIn('private-source',str(error.exception))
        self.assertTrue(state.closed)

    def test_size_and_offset_limits_reject_before_loading_browser(self):
        for text,co in (('x'*(MAX_PRIVATE_BYTES+1),0),(RAW,-1),(RAW,True),('\ud800',0)):
            with self.assertRaises(CoordinateError):verify_source(text,co)

    def test_optional_lua_probe_receives_memory_data_without_echoing_it(self):
        state,module=self.browser()
        with patch.dict('sys.modules',{'playwright.sync_api':module}), \
             patch('source_parser_preflight.check_lua',return_value=dict(lua_verified=True,lua_positions=1)) as lua:
            result=verify_source(RAW,RAW.index('只'),lua_command=['local-probe'])
        self.assertEqual(lua.call_args.args[0],['local-probe'])
        self.assertEqual(lua.call_args.args[1],[RAW])
        self.assertEqual(lua.call_args.kwargs['targets'],[RAW.index('只')])
        self.assertTrue(result['lua_verified'])
        self.assertNotIn(RAW,str(result))
        self.assertTrue(state.closed)


if __name__=='__main__':
    unittest.main()
