"""Offline reading-flag contracts; no Keychain, browser or upstream calls."""
from contextlib import redirect_stdout
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import verify_shelf_flags as probe
from shelf_flags_contract import flag
from web_shelf_contract import normalize
from test_eink_login import Opener


def shelf():
    return dict(books=[dict(bookId='99009900',title='PRIVATE-SHELF-TITLE',finishReading=0,finished=1,secret=1)],archive=[])


class ShelfFlagTests(unittest.TestCase):
    def test_default_does_not_read_keychain_or_network(self):
        with patch.object(probe,'SessionStore') as store,patch.object(probe,'NativeFlagsProbe') as network,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(probe.main([]),0)
        store.assert_not_called();network.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_binary_false_preserved_and_other_values_unknown(self):
        for value in (0,False,1,True):self.assertEqual(flag(dict(secret=value),'secret'),dict(value=bool(value)))
        for value in ('0','1','true',2,-1,None,{},float('nan'),float('inf')):
            with self.subTest(value_type=type(value)):self.assertEqual(flag(dict(secret=value),'secret'),dict(reason='invalid'))
        self.assertEqual(flag({},'secret'),dict(reason='missing'))

    def test_reading_completion_is_independent(self):
        result=probe.project(shelf())[0]
        self.assertFalse(result['finished']['value']);self.assertTrue(result['private']['value'])
        self.assertEqual(result['pinned'],dict(reason='missing'))
        self.assertEqual(probe.project(dict(books=[dict(bookId='1',title='Synthetic',finished=1,progress=100)]))[0]['finished'],dict(reason='missing'))

    def test_projection_normalizes_bool_flags_without_aliases(self):
        source=shelf();source['books'][0].update(secret=False,finishReading=True,isTop=False)
        row=normalize(source)['books'][0]
        self.assertEqual((row['secret'],row['finishReading'],row['isTop']),(0,1,False))
        self.assertEqual(row['finished'],1)

    def test_native_guard_allows_one_known_get_only(self):
        opener=Opener([shelf()]);native=probe.NativeFlagsProbe(opener)
        native.request('shelf_flags','https://i.weread.qq.com/shelf/sync')
        for stage,url,body in [('shelf_flags','https://i.weread.qq.com/shelf/sync',{}),
            ('shelf_flags','https://i.weread.qq.com/shelf/sync?x=1',None),('login','https://i.weread.qq.com/login',{}),
            ('shelf_flags','https://i.weread.qq.com/shelf/add',dict(bookIds=['99009900']))]:
            with self.assertRaises(probe.ProbeError):native.request(stage,url,body)
        self.assertEqual(len(opener.requests),1)

    def test_web_guard_rejects_other_read_and_write_paths(self):
        web=probe.WebFlagsProbe()
        for stage,url,body in [('reader','https://weread.qq.com/web/reader/example',None),
            ('shelf','https://weread.qq.com/web/shelf/sync',{}),('renew','https://weread.qq.com/web/login/renewal',{})]:
            with self.assertRaises(probe.PreflightError):web.guard(stage,url,body)
        web.close()

    def run_saved(self,child_failed=False):
        credentials=dict(vid='88008800',accessToken='PRIVATE-ACCESS-SENTINEL',refreshToken='PRIVATE-REFRESH-SENTINEL',deviceId='PRIVATE-DEVICE-SENTINEL')
        saved=dict(vid='88008800',cookies=dict(wr_skey='PRIVATE-COOKIE-SENTINEL'))
        web=SimpleNamespace(vid=None,set_cookie=lambda *_:None,verify_account=lambda:None,request=lambda *_:shelf(),close=lambda:None,report=dict(stages=[]))
        native=SimpleNamespace(request=lambda *_a,**_k:shelf(),report=dict(stages=[]))
        args=['--saved-session']+(['--native-http','--lua-command','synthetic'] if child_failed else [])
        with patch.object(probe,'SessionStore') as store,patch.object(probe,'NativeSessionStore') as native_store,\
            patch.object(probe,'WebFlagsProbe',return_value=web),patch.object(probe,'NativeFlagsProbe',return_value=native),\
            patch.object(probe,'save_refreshed_web_session',return_value=False),\
            patch.object(probe.subprocess,'run',return_value=SimpleNamespace(returncode=1,stdout=b'PRIVATE-CHILD-SENTINEL')) as child,\
            redirect_stdout(io.StringIO()) as out:
            store.return_value.load.return_value=saved;native_store.return_value.load.return_value=credentials
            code=probe.main(args)
            native_store.return_value.load.assert_called_once_with('88008800')
        return code,out.getvalue(),credentials,saved,child

    def test_saved_projection_report_contains_no_private_fields(self):
        code,text,credentials,saved,child=self.run_saved()
        self.assertEqual(code,0);child.assert_not_called()
        self.assertEqual(credentials,{});self.assertEqual(saved,{})
        for value in ('PRIVATE-','88008800','99009900'):self.assertNotIn(value,text)
        value=json.loads(text);self.assertEqual(value['account_data_writes'],0)
        self.assertTrue(value['shelf_write_preview_reading_state_matches'])

    def test_failed_private_child_output_is_not_echoed(self):
        code,text,credentials,saved,child=self.run_saved(True)
        self.assertEqual(code,1);self.assertEqual(credentials,{});self.assertEqual(saved,{})
        self.assertIn(b'PRIVATE-ACCESS-SENTINEL',child.call_args.kwargs['input'])
        self.assertNotIn('PRIVATE-',text);self.assertEqual(json.loads(text)['result'],'UNVERIFIED')


if __name__=='__main__':unittest.main()
