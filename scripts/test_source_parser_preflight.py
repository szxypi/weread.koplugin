from contextlib import contextmanager
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from source_parser_preflight import MAX_PRIVATE_BYTES, PUBLIC_READER, verify_source,verify_source_batched,source_batches
from verify_source_coordinates import CoordinateError,FilteredSource

RAW='<html><body><p>只在内存核对的独特原文内容。</p></body></html>'


class SourceParserPreflightTests(unittest.TestCase):
    def browser(self, cookies=None, fail=False, source=RAW, rows=None):
        state=SimpleNamespace(offline=False,closed=False,socket_blocked=False,routes=[],private_evaluated=False)
        def evaluate(_script,sources):
            self.assertTrue(state.offline)
            self.assertTrue(state.socket_blocked)
            self.assertEqual(sources,[source])
            state.private_evaluated=True
            if fail:raise RuntimeError('private-source-must-not-appear')
            return [rows if rows is not None else [dict(co=source.index('只'),text='只')]]
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

    def test_multiple_bodies_are_explicit_and_cannot_use_single_body_lua_probe(self):
        second='<html><body><p>第二个正文包含独特文本。</p></body></html>'
        source=RAW+second
        state,module=self.browser(source=source,rows=[dict(co=source.index('只'),text='只'),dict(co=source.index('第二'),text='第二')])
        with patch.dict('sys.modules',{'playwright.sync_api':module}), \
             patch('source_parser_preflight.FilteredSource',wraps=FilteredSource) as model:
            result=verify_source(source,source.index('第二'),allow_multiple_bodies=True)
        self.assertTrue(model.call_args.kwargs['allow_multiple_bodies'])
        self.assertTrue(result['official_parser_target_present'])
        self.assertTrue(state.offline and state.closed)
        for value in ('yes',1,None):
            with self.assertRaises(CoordinateError):verify_source(RAW,15,allow_multiple_bodies=value)
        with self.assertRaises(CoordinateError):verify_source(RAW,15,lua_command=['single-body'],allow_multiple_bodies=True)

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

    def test_body_aligned_batches_reconstruct_utf16_coordinates_offline(self):
        raw=('<html><body><p>甲😀独特文本 &amp; first passage.</p></body></html>'
             '<html><body><p>第二段独特内容 and more words.</p></body></html>'
             '<html><body><p>最后一段不同的内容 and ending.</p></body></html>')
        state=SimpleNamespace(closed=False,offline=True,calls=0)
        def evaluate(_script,sources):
            self.assertTrue(state.offline);self.assertEqual(len(sources),1);state.calls+=1
            model=FilteredSource(sources[0],allow_multiple_bodies=True)
            return [[dict(co=co,text=char) for co,char in zip(model.starts,model.characters)]]
        @contextmanager
        def browser():
            try:yield SimpleNamespace(evaluate=evaluate),'synthetic'
            finally:state.closed=True
        full=FilteredSource(raw,allow_multiple_bodies=True);target=full.starts[-1]
        with patch('source_parser_preflight.MAX_PRIVATE_BYTES',90),patch('source_parser_preflight.offline_parser',browser):
            result=verify_source_batched(raw,target)
        self.assertTrue(result['official_parser_batches_verified'] and result['model_segments_reconstructed'])
        self.assertFalse(result['official_parser_full_source_verified']);self.assertGreater(result['batches'],1)
        self.assertEqual(result['body_count'],3);self.assertEqual(state.calls,result['batches']);self.assertTrue(state.closed)
        self.assertTrue(result['official_parser_target_present']);self.assertNotIn(raw,str(result))

    def test_batch_boundaries_refuse_oversize_and_incomplete_parts(self):
        for raw in ('<html>no body</html>','<body>unclosed', '<body><body>nested</body></body>'):
            with self.assertRaises(CoordinateError):verify_source_batched(raw,0)
        with patch('source_parser_preflight.MAX_PRIVATE_BYTES',20):
            with self.assertRaises(CoordinateError):source_batches('<body><p>'+('x'*40)+'</p></body>')
        with self.assertRaises(CoordinateError):verify_source_batched(RAW,True)

    def test_batch_composition_disagreement_fails_and_closes_browser(self):
        raw='<body><p>First synthetic passage.</p></body><body><p>Second synthetic passage.</p></body>'
        state=SimpleNamespace(closed=False,calls=0)
        @contextmanager
        def browser():
            try:yield SimpleNamespace(evaluate=lambda _script,_sources:[[dict(co=0,text='x')]]),'synthetic'
            finally:state.closed=True
        def model(_raw,**_kwargs):
            state.calls+=1
            return SimpleNamespace(segments=[(0,'whole' if state.calls==1 else 'part')],body_count=2)
        with patch('source_parser_preflight.MAX_PRIVATE_BYTES',50),patch('source_parser_preflight.offline_parser',browser), \
             patch('source_parser_preflight.FilteredSource',side_effect=model),patch('source_parser_preflight.check_parser_rows',return_value=1):
            with self.assertRaisesRegex(CoordinateError,'^parser: batch composition mismatch$'):verify_source_batched(raw,0)
        self.assertTrue(state.closed)


if __name__=='__main__':
    unittest.main()
