"""CB_ metadata/cycle boundaries using synthetic responses only."""
from contextlib import redirect_stdout,redirect_stderr
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch,Mock

from fetch_weread_epub import reader_url_for
from test_cb_progress import FIRST,SECOND
from test_eink_login import Opener
from verify_cb_metadata import (BASE,NATIVE_BASE,CbMetadataError,CbNativeMetadataProbe,CbMetadataWebProbe,
                                inspect_channel,main,validate_catalog,valid_errors)


def source(identity=FIRST):
    return dict(bookId=identity,title='Private title',author='Private author',totalWords=1234,
                token='private-token',bookVersion=71,chapterOffset=19,progress=70)


def html(identity=FIRST):
    return '<script>window.__INITIAL_STATE__='+json.dumps(dict(reader=dict(bookInfo=source(identity))))+';(function(){})();</script>'


def catalog(identity=FIRST):return [dict(bookId=identity,updated=[dict(chapterUid=1,title='Private chapter')])]


def web_probe():
    probe=CbMetadataWebProbe();probe.vid='900000';probe.authenticated=True;probe.allowed={FIRST,SECOND};probe.book_id=FIRST
    probe.set_cookie('wr_vid','900000');probe.set_cookie('wr_skey','synthetic-web-token')
    return probe


class CbMetadataTests(unittest.TestCase):
    def test_native_guards_fixed_selected_cb_gets_once_each(self):
        probe=CbNativeMetadataProbe();probe.allowed_ids={FIRST}
        probe.guard('metadata_shelf',NATIVE_BASE+'/shelf/sync',None)
        probe.guard('metadata',NATIVE_BASE+'/book/info?bookId='+FIRST,None)
        for stage,url,body in [('metadata',NATIVE_BASE+'/book/info?bookId='+FIRST,None),
                               ('metadata',NATIVE_BASE+'/book/info?bookId='+SECOND,None),
                               ('metadata',NATIVE_BASE+'/book/info?bookId=41',None),
                               ('metadata',NATIVE_BASE+'/book/info?bookId='+FIRST,{}),
                               ('write',NATIVE_BASE+'/shelf/delete',dict(bookIds=[FIRST]))]:
            with self.assertRaises(Exception):probe.guard(stage,url,body)

    def test_web_only_selected_reader_and_explicit_single_catalog_are_allowed(self):
        probe=web_probe()
        probe.guard('reader',reader_url_for(FIRST),None)
        with self.assertRaises(CbMetadataError):probe.guard('reader',reader_url_for(FIRST),None)
        with self.assertRaises(CbMetadataError):probe.guard('catalog_before',BASE+'/web/book/chapterInfos',dict(bookIds=[FIRST]))
        probe.catalog_book=FIRST
        probe.guard('catalog_before',BASE+'/web/book/chapterInfos',dict(bookIds=[FIRST]))
        with self.assertRaises(CbMetadataError):probe.guard('catalog_before',BASE+'/web/book/chapterInfos',dict(bookIds=[FIRST]))
        for stage,url,body in [('reader',reader_url_for(SECOND),None),('reader',reader_url_for(FIRST)+'?extra=1',None),
                               ('e_0',BASE+'/web/book/chapter/e_0',{}),('login',BASE+'/login',{}),
                               ('write',BASE+'/web/book/read',{}),('shelf',BASE+'/web/shelf/add',{})]:
            with self.assertRaises(Exception):probe.guard(stage,url,body)

    def test_foreign_cookie_stops_before_http_and_invalidates_owner_verification(self):
        probe=web_probe();probe.set_cookie('wr_vid','900099');probe.opener=Mock()
        with self.assertRaises(CbMetadataError):probe.request('reader',reader_url_for(FIRST))
        probe.opener.open.assert_not_called();self.assertFalse(probe.authenticated)

    def test_owner_change_in_response_cannot_continue_or_save_as_verified(self):
        probe=web_probe();opener=Opener([dict(bookId=FIRST)])
        open_request=opener.open
        def changed(*args,**kwargs):
            reply=open_request(*args,**kwargs);probe.set_cookie('wr_vid','900099');return reply
        opener.open=changed;probe.opener=opener
        with self.assertRaises(CbMetadataError):probe.request('reader',reader_url_for(FIRST))
        self.assertFalse(probe.authenticated);self.assertEqual(len(opener.requests),1)

    def test_native_projection_has_only_display_fields(self):
        result,samples=inspect_channel([FIRST],lambda _id:source(),native=True)
        self.assertTrue(result['verified']);self.assertEqual(result['books'],1)
        self.assertEqual(samples[0]['expected'],dict(bookId=FIRST,title='Private title',author='Private author',wordCount=1234))
        for private in (FIRST,'Private title','private-token'):self.assertNotIn(private,json.dumps(result))

    def test_web_projection_is_parsed_without_executing_page_code(self):
        result,samples=inspect_channel([FIRST],lambda _id:html())
        self.assertTrue(result['verified']);self.assertEqual(samples[0]['expected'],dict(bookId=FIRST,title='Private title',author='Private author'))
        result,samples=inspect_channel([FIRST],lambda _id:'<script>throw "Private title";</script>')
        self.assertFalse(result['verified']);self.assertEqual(samples,[])

    def test_failed_channel_stops_its_remaining_reads(self):
        calls=[]
        def read(identity):calls.append(identity);raise ValueError('private-response')
        result,samples=inspect_channel([FIRST,SECOND],read,native=True)
        self.assertFalse(result['verified']);self.assertEqual(calls,[FIRST]);self.assertEqual(samples,[])

    def test_explicit_error_flags_types_and_identity_are_rejected(self):
        for value in ({'errCode':False},{'errcode':-1},{'succ':0},{'succ':'1'},{'errcode':0.0},[]):
            with self.assertRaises(CbMetadataError):valid_errors(value)
        for value in (dict(errcode=0,succ=1),dict(errCode=None,succ=True),{}):valid_errors(value)
        result,_samples=inspect_channel([FIRST],lambda _id:source(SECOND),native=True)
        self.assertFalse(result['verified'])

    def test_catalog_identity_uniqueness_and_complete_rows_are_checked(self):
        self.assertEqual(validate_catalog(catalog(),FIRST),1)
        invalid=[catalog(SECOND),[dict(bookId=FIRST,updated=[])],
                 [dict(bookId=FIRST,updated=[dict(chapterUid=1)]*2)],
                 [dict(bookId=FIRST,updated=[dict(chapterUid=True)])],
                 [dict(bookId=FIRST,updated=[dict(chapterUid=1),{}])],
                 [dict(bookId=FIRST,errCode=-1,updated=[dict(chapterUid=1)])]]
        for value in invalid:
            with self.assertRaises(Exception):validate_catalog(value,FIRST)


class CliTests(unittest.TestCase):
    def test_offline_and_unpaired_online_options_never_open_stores(self):
        with patch('verify_cb_metadata.SessionStore') as store,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main([]),0)
        store.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')
        for args in (['--catalog'],['--lua-channel','native'],['--lua-command','synthetic']):
            with patch('verify_cb_metadata.SessionStore') as store,redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):main(args)
            store.assert_not_called()

    def invoke(self,*,web_failure=False,catalog_enabled=False,lua=False):
        saved=dict(vid='900000',cookies={'wr_vid':'900000','wr_skey':'private-cookie'})
        credentials=dict(vid='900000',accessToken='private-access')
        native=SimpleNamespace(request=Mock(side_effect=[dict(books=[dict(bookId=FIRST)]),source()]),
                               report=dict(stages=[]),allowed_ids=set())
        web=SimpleNamespace(vid=None,allowed=set(),set_cookie=Mock(),verify_account=Mock(),close=Mock(),book_id=None,catalog_book=None,
                            report=dict(stages=[]),request=Mock(side_effect=[dict(books=[dict(bookId=FIRST)]),
                               '<invalid>' if web_failure else html(),catalog()]))
        expected=dict(bookId=FIRST,title='Private title',author='Private author',wordCount=1234)
        child=SimpleNamespace(returncode=0,stdout=b'\nWEREAD_METADATA_RESULT='+json.dumps(dict(model=[expected],native=[expected],requests=1)).encode())
        args=['--saved-session']+(['--catalog'] if catalog_enabled else [])+(['--lua-channel','native','--lua-command','synthetic'] if lua else [])
        with patch('verify_cb_metadata.SessionStore') as store,patch('verify_cb_metadata.NativeSessionStore') as native_store,\
             patch('verify_cb_metadata.CbNativeMetadataProbe',return_value=native),patch('verify_cb_metadata.CbMetadataWebProbe',return_value=web),\
             patch('verify_cb_metadata.save_refreshed_web_session',return_value=False),\
             patch('verify_cb_metadata.subprocess.run',return_value=child) as run,redirect_stdout(io.StringIO()) as out:
            store.return_value.load.return_value=saved;native_store.return_value.load.return_value=credentials
            code=main(args)
        self.assertEqual(saved,{});self.assertEqual(credentials,{});web.close.assert_called_once()
        store.return_value.delete.assert_not_called();native_store.return_value.delete.assert_not_called()
        for private in (FIRST,'900000','Private title','Private author','private-access','private-cookie','private-token'):
            self.assertNotIn(private,out.getvalue())
        return code,json.loads(out.getvalue()),web,run

    def test_verified_channels_report_only_counts(self):
        code,result,_web,run=self.invoke()
        self.assertEqual(code,0);self.assertEqual(result['result'],'CB_METADATA_READ_VERIFIED');run.assert_not_called()
        self.assertEqual(result['verified_channels'],['native','web']);self.assertEqual(result['read_only_catalog_posts_attempted'],0)

    def test_failed_web_does_not_discard_verified_native_or_repeat(self):
        code,result,web,_run=self.invoke(web_failure=True)
        self.assertEqual(code,0);self.assertEqual(result['result'],'CB_METADATA_PARTIAL_VERIFIED')
        self.assertEqual(result['verified_channels'],['native']);self.assertEqual(web.request.call_count,2)

    def test_catalog_is_one_explicit_read_body_for_the_bound_cb_book(self):
        code,result,web,_run=self.invoke(catalog_enabled=True)
        self.assertEqual(code,0);self.assertTrue(result['catalog_verified']);self.assertEqual(result['catalog_chapters'],1)
        self.assertEqual(result['read_only_catalog_posts_attempted'],1)
        self.assertEqual(web.request.call_args.args,('catalog_before',BASE+'/web/book/chapterInfos',dict(bookIds=[FIRST])))

    def test_native_lua_projection_uses_only_captured_pipe(self):
        code,result,_web,run=self.invoke(lua=True)
        self.assertEqual(code,0);self.assertTrue(result['lua_model_and_https_match'])
        payload=json.loads(run.call_args.kwargs['input'])
        self.assertTrue(payload['cb_metadata']);self.assertEqual(payload['native_credentials']['vid'],'900000')
        self.assertEqual(result['lua_metadata_gets'],1)


if __name__=='__main__':unittest.main()
