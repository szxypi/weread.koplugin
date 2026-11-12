"""CB_ display reads with synthetic HTTP and stores; no real account or network."""
from contextlib import redirect_stdout,redirect_stderr
from http.cookiejar import CookieJar,Cookie
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch,Mock
from urllib.error import HTTPError,URLError

from test_eink_login import Opener
from verify_cb_progress import BASE,CbError,CbProgressProbe,cb_id,cb_ids,main
from verify_shelf_progress import parse,DisplayError

FIRST='CB_SyntheticAlpha'
SECOND='CB_SyntheticBeta'


def shelf(*identities):return dict(books=[dict(bookId=value) for value in identities])


def progress(identity=FIRST,value=37.8):return dict(book=dict(bookId=identity,progress=value),private='private-position')


class CbProgressTests(unittest.TestCase):
    def test_identifier_is_bounded_ascii_and_does_not_accept_numeric_or_other_namespaces(self):
        for value in (FIRST,'CB_1','CB_'+'A'*64):self.assertEqual(cb_id(value),value)
        for value in (True,41,None,{},'41','MP_WXS_a','cb_abc','CB_','CB_'+'a'*65,'CB_abc/x','CB_a?b=1',
                      'CB_a%2f','CB_a_b','CB_a-b','CB_中文','CB_a\n'):
            self.assertIsNone(cb_id(value))

    def test_native_web_selection_requires_unique_complete_bounded_cb_sets(self):
        self.assertEqual(cb_ids(shelf('41',SECOND,FIRST,'MP_WXS_a')),sorted([FIRST,SECOND]))
        for value in ({},shelf(),shelf('41'),shelf(FIRST,FIRST),shelf(*('CB_'+str(n) for n in range(9))),
                      shelf('CB_invalid/'),dict(books=[{}]),dict(books=[dict(bookId=True)])):
            with self.assertRaises(CbError):cb_ids(value)

    def test_fixed_get_cookie_origin_and_encoded_reader_reference_have_no_native_auth(self):
        opener=Opener([progress()]);probe=CbProgressProbe({'wr_skey':'XXX-private-cookie'},[FIRST],opener)
        self.assertEqual(parse(probe.fetch(FIRST),FIRST),37)
        request=opener.requests[0]
        self.assertEqual(request.full_url,BASE+'/web/book/getProgress?bookId='+FIRST)
        self.assertEqual(request.get_method(),'GET');self.assertIsNone(request.data)
        self.assertEqual(request.get_header('Cookie'),'wr_skey=XXX-private-cookie')
        self.assertTrue(request.get_header('Referer').startswith(BASE+'/web/reader/'))
        for header in ('Authorization','Vid','Accesstoken'):self.assertIsNone(request.get_header(header))
        self.assertEqual(probe.stages,[dict(stage='cb_progress',status=200)])

    def test_consumed_address_unknown_identity_or_closed_probe_never_dispatches(self):
        opener=Opener([progress()]);probe=CbProgressProbe({'wr_skey':'private-cookie'},[FIRST],opener)
        probe.fetch(FIRST)
        for identity in (FIRST,SECOND,'41',{},'CB_a?bookId=41'):
            with self.assertRaises(CbError):probe.fetch(identity)
        probe.close()
        with self.assertRaises(CbError):probe.fetch(FIRST)
        self.assertEqual(len(opener.requests),1);self.assertEqual(probe.cookie,'')

    def test_http_failure_closes_response_and_never_retries(self):
        error=HTTPError(BASE,401,'private',{},io.BytesIO(b'private-body'))
        opener=Opener([error]);probe=CbProgressProbe({'wr_skey':'private-cookie'},[FIRST],opener)
        with self.assertRaises(CbError):probe.fetch(FIRST)
        self.assertTrue(error.closed);self.assertEqual(probe.stages[-1]['status'],401)
        with self.assertRaises(CbError):probe.fetch(FIRST)
        self.assertEqual(len(opener.requests),1)

    def test_network_failure_is_sanitized_and_no_automatic_retry(self):
        for error in (TimeoutError('private-token'),URLError('private-token')):
            opener=Opener([error]);probe=CbProgressProbe({'wr_skey':'private-cookie'},[FIRST],opener)
            with self.assertRaisesRegex(CbError,'cb_connection_unverified'):probe.fetch(FIRST)
            self.assertNotIn('private-token',json.dumps(probe.stages));self.assertEqual(len(opener.requests),1)

    def test_size_invalid_json_and_non_object_responses_are_rejected(self):
        for value in (dict(private='x'*65536),[],None):
            probe=CbProgressProbe({'wr_skey':'private-cookie'},[FIRST],Opener([value]))
            with self.assertRaises(CbError):probe.fetch(FIRST)

    def test_identity_errors_and_percent_types_remain_strict(self):
        for value in (progress(SECOND),dict(errCode=-1,book=dict(progress=37)),progress(value=True),
                      progress(value='37'),progress(value=-1),progress(value=101),progress(value=float('nan'))):
            with self.assertRaises(DisplayError):parse(value,FIRST)
        self.assertIsNone(parse(dict(recordReadingTime=1),FIRST))

    def test_invalid_cookie_or_selection_is_refused_before_network(self):
        for cookies,ids in (({},[FIRST]),({'other':'private'},[FIRST]),({'wr_skey':'bad\n'},[FIRST]),
                            ({'wr_skey':'bad😀'},[FIRST]),({'wr_skey':'private'},[]),
                            ({'wr_skey':'private'},[FIRST,FIRST]),({'wr_skey':'private'},['41'])):
            with self.assertRaises(CbError):CbProgressProbe(cookies,ids,Mock())


class CliTests(unittest.TestCase):
    def test_default_and_invalid_native_mode_do_not_load_credentials(self):
        with patch('verify_cb_progress.SessionStore') as store,patch('verify_cb_progress.NativeProbe') as native,\
             redirect_stdout(io.StringIO()) as out:self.assertEqual(main([]),0)
        store.assert_not_called();native.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')
        with patch('verify_cb_progress.SessionStore') as store,redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):
            main(['--native-http'])
        store.assert_not_called()

    def invoke(self,*,web_ids=(FIRST,SECOND),responses=None,lua=None):
        cookies={'wr_vid':'88008800','wr_skey':'private-cookie'}
        saved=dict(vid='88008800',cookies=cookies)
        credentials=dict(vid='88008800',accessToken='private-access')
        jar=CookieJar()
        for key,value in cookies.items():
            jar.set_cookie(Cookie(0,key,value,None,False,'.weread.qq.com',True,True,'/',True,True,None,True,None,None,{},False))
        native=SimpleNamespace(request=Mock(return_value=shelf('41',FIRST,SECOND)))
        web=SimpleNamespace(vid=None,set_cookie=Mock(),verify_account=Mock(),request=Mock(return_value=shelf(*web_ids)),cookies=jar,close=Mock())
        opener=Opener(responses if responses is not None else [progress(FIRST),progress(SECOND,0)])
        args=['--saved-session']+(['--native-http','--lua-command','synthetic'] if lua is not None else [])
        with patch('verify_cb_progress.SessionStore') as store,patch('verify_cb_progress.NativeSessionStore') as native_store,\
             patch('verify_cb_progress.NativeProbe',return_value=native),patch('verify_cb_progress.WebSourceProbe',return_value=web),\
             patch('verify_cb_progress.save_refreshed_web_session',return_value=False),\
             patch('verify_cb_progress.build_opener',return_value=opener),\
             patch('verify_cb_progress.subprocess.run',return_value=lua) as child,redirect_stdout(io.StringIO()) as out:
            store.return_value.load.return_value=saved;native_store.return_value.load.return_value=credentials
            code=main(args)
        self.assertEqual(saved,{});self.assertEqual(credentials,{});web.close.assert_called_once()
        store.return_value.delete.assert_not_called();native_store.return_value.delete.assert_not_called()
        for private in (FIRST,SECOND,'88008800','private-cookie','private-access','private-position'):
            self.assertNotIn(private,out.getvalue())
        return code,json.loads(out.getvalue()),opener,child

    def test_matched_two_channel_shelves_allow_only_selected_reads_and_export_counts(self):
        code,value,opener,child=self.invoke()
        self.assertEqual(code,0);self.assertEqual(value['result'],'CB_DISPLAY_PROGRESS_READ_VERIFIED')
        self.assertEqual(value['cb_books'],2);self.assertEqual(value['known_progress'],2)
        self.assertEqual(value['cb_progress_gets'],2);self.assertEqual(len(opener.requests),2);child.assert_not_called()

    def test_changed_shelf_stops_before_any_cb_read(self):
        code,value,opener,_child=self.invoke(web_ids=(FIRST,))
        self.assertEqual(code,1);self.assertEqual(value['cb_progress_gets'],0);self.assertEqual(opener.requests,[])

    def test_unknown_first_response_stops_remaining_without_retry(self):
        code,value,opener,_child=self.invoke(responses=[dict(errCode=-1)])
        self.assertEqual(code,1);self.assertEqual(value['cb_progress_gets'],1);self.assertEqual(len(opener.requests),1)

    def test_native_lua_comparison_requires_exact_model_readback_and_count(self):
        expected=[dict(book_id=FIRST,percent=37),dict(book_id=SECOND,percent=0)]
        payload=dict(model=expected,native=expected,requests=2)
        code,value,_opener,child=self.invoke(lua=SimpleNamespace(returncode=0,stdout=b'\nWEREAD_DISPLAY_RESULT='+json.dumps(payload).encode()))
        self.assertEqual(code,0);self.assertTrue(value['lua_https_matches']);self.assertEqual(value['lua_progress_gets'],2)
        self.assertEqual(json.loads(child.call_args.kwargs['input'])['samples'][0]['book_id'],FIRST)
        payload['requests']=1
        code,value,_opener,_child=self.invoke(lua=SimpleNamespace(returncode=0,stdout=b'\nWEREAD_DISPLAY_RESULT='+json.dumps(payload).encode()))
        self.assertEqual(code,1);self.assertNotIn('lua_https_matches',value)


if __name__=='__main__':unittest.main()
