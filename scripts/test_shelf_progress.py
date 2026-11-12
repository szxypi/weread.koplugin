"""Synthetic display contract only; never opens the real Keychain or network."""
from contextlib import redirect_stdout,redirect_stderr
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from verify_shelf_progress import DisplayError,main,parse,anonymous_progress


class DisplayTests(unittest.TestCase):
    def test_real_contract_percent_units_and_display_rounding(self):
        for value in (0,1,37.8,99.99,100):
            self.assertEqual(parse(dict(book=dict(bookId='900001',progress=value)),'900001'),int(value))

    def test_duration_only_is_unknown_not_zero_percent(self):
        self.assertIsNone(parse(dict(recordReadingTime=100),'900001'))

    def test_errors_identity_malformed_and_out_of_range_fail(self):
        for value in ({},[],dict(book=dict(progress=True)),dict(book=dict(progress='37')),dict(book=dict(progress=-1)),
                      dict(book=dict(progress=101)),dict(book=dict(progress=float('nan'))),
                      dict(bookId='900002',recordReadingTime=12),dict(book=dict(bookId='900002',progress=37)),
                      dict(errcode=-1,book=dict(progress=37)),dict(succ=0,recordReadingTime=100)):
            with self.assertRaises(DisplayError):parse(value,'900001')

    def test_default_never_loads_credentials_or_opens_network(self):
        with patch('verify_shelf_progress.SessionStore') as store,patch('verify_shelf_progress.WebSourceProbe') as probe,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main([]),0)
        store.assert_not_called();probe.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_saved_result_has_no_identifiers_positions_or_credentials(self):
        with patch('verify_shelf_progress.SessionStore') as store,patch('verify_shelf_progress.WebSourceProbe') as probe,redirect_stdout(io.StringIO()) as out:
            store.return_value.load.return_value=dict(vid='88008800',cookies=dict(wr_skey='private-sentinel'))
            probe.return_value.request.side_effect=[dict(books=[dict(bookId='99009900')]),dict(book=dict(progress=37.8))]
            probe.return_value.report=dict(stages=[dict(stage='account',status=200)])
            self.assertEqual(main(['--saved-session']),0)
        for private in ('88008800','99009900','private-sentinel','37.8'):
            self.assertNotIn(private,out.getvalue())
        self.assertEqual(json.loads(out.getvalue())['display_progress_count'],1)

    def test_refreshed_verified_session_saved_before_optional_native_failure(self):
        cookies=[SimpleNamespace(name=k,value=v,domain='.weread.qq.com',path='/')
                 for k,v in dict(wr_vid='88008800',wr_skey='new-private-sentinel').items()]
        probe=SimpleNamespace(vid=None,authenticated=True,cookies=cookies,set_cookie=lambda *_:None,verify_account=lambda:None,
                              request=lambda stage,*_:dict(books=[dict(bookId='99009900')]) if stage=='shelf' else dict(book=dict(progress=37.8)),
                              close=lambda:None,report=dict(stages=[]))
        response=SimpleNamespace(returncode=1,stdout=b'\nWEREAD_DISPLAY_RESULT={"stage":"fetch","statuses":[429]}\n')
        with patch('verify_shelf_progress.SessionStore') as store,patch('verify_shelf_progress.WebSourceProbe',return_value=probe),\
                patch('verify_shelf_progress.subprocess.run',return_value=response) as child,redirect_stdout(io.StringIO()) as out:
            store.return_value.load.return_value=dict(vid='88008800',cookies=dict(wr_vid='88008800',wr_skey='old-private-sentinel'))
            self.assertEqual(main(['--saved-session','--native-http','--lua-command','synthetic-probe']),1)
            store.return_value.save.assert_called_once_with(probe)
        self.assertTrue(json.loads(out.getvalue())['refreshed_session_saved_to_keychain'])
        self.assertNotIn('private-sentinel',out.getvalue())
        self.assertEqual(child.call_args.args[0],['synthetic-probe'])
        self.assertEqual(json.loads(child.call_args.kwargs['input'])['session']['cookies']['wr_skey'],'new-private-sentinel')

    def test_service_failure_stops_remaining_sample_reads(self):
        from verify_web_source_progress import PreflightError
        with patch('verify_shelf_progress.SessionStore') as store,patch('verify_shelf_progress.WebSourceProbe') as probe,redirect_stdout(io.StringIO()) as out:
            store.return_value.load.return_value=dict(vid='88008800',cookies={})
            probe.return_value.request.side_effect=[dict(books=[dict(bookId='99009900'),dict(bookId='99009901')]),PreflightError('http_rejected')]
            self.assertEqual(main(['--saved-session']),1)
        self.assertEqual(probe.return_value.request.call_count,2)
        self.assertEqual(json.loads(out.getvalue())['reason'],'http_rejected')

    def test_anonymous_control_has_no_credentials_or_redirects(self):
        class Reply:
            status=200
            def __enter__(self):return self
            def __exit__(self,*_):pass
            def read(self,_):return b'{"errCode":-2010}'
        with patch('verify_shelf_progress.build_opener') as opener:
            opener.return_value.open.return_value=Reply()
            result=anonymous_progress('99009900')
        request=opener.return_value.open.call_args.args[0]
        self.assertEqual(request.get_method(),'GET');self.assertIsNone(request.data)
        self.assertIsNone(request.get_header('Cookie'));self.assertIsNone(request.get_header('Authorization'))
        self.assertEqual(result['error_code'],-2010);self.assertFalse(result['login_rejected'])
        self.assertNotIn('99009900',json.dumps(result))

    def test_anonymous_login_detection_is_narrow(self):
        class Reply:
            def __enter__(self):return self
            def __exit__(self,*_):pass
            def read(self,_):return self.raw
        for status,raw,login in ((401,b'private-html',True),(200,b'{"errCode":-2012}',True),
                                 (200,b'{"errCode":-2010}',False),(429,b'private-html',False),
                                 (200,b'{"errCode":-2012,"errcode":-2010}',False)):
            reply=Reply();reply.status,reply.raw=status,raw
            with patch('verify_shelf_progress.build_opener') as opener:
                opener.return_value.open.return_value=reply
                self.assertEqual(anonymous_progress('99009900')['login_rejected'],login)

    def test_anonymous_control_is_bounded(self):
        class Reply:
            status=200
            def __enter__(self):return self
            def __exit__(self,*_):pass
            def read(self,size):self.size=size;return b'x'*size
        reply=Reply()
        with patch('verify_shelf_progress.build_opener') as opener:
            opener.return_value.open.return_value=reply
            with self.assertRaises(DisplayError):anonymous_progress('99009900')
        self.assertEqual(reply.size,65537)
        with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):main(['--anonymous-control'])

    def test_newer_cookie_authority_cannot_be_overwritten(self):
        cookies=[SimpleNamespace(name=k,value=v,domain='.weread.qq.com',path='/')
                 for k,v in dict(wr_vid='88008800',wr_skey='new-private-sentinel').items()]
        probe=SimpleNamespace(vid=None,authenticated=True,cookies=cookies,set_cookie=lambda *_:None,verify_account=lambda:None,
                              request=lambda stage,*_:dict(books=[dict(bookId='99009900')]) if stage=='shelf' else dict(book=dict(progress=37.8)),
                              close=lambda:None,report=dict(stages=[]))
        saved=dict(vid='88008800',cookies=dict(wr_vid='88008800',wr_skey='old-private-sentinel'))
        with patch('verify_shelf_progress.SessionStore') as store,patch('verify_shelf_progress.WebSourceProbe',return_value=probe),\
                patch('verify_shelf_progress.subprocess.run') as child,redirect_stdout(io.StringIO()) as out:
            store.return_value.load.side_effect=[saved,dict(saved,cookies={})]
            self.assertEqual(main(['--saved-session']),1)
            store.return_value.save.assert_not_called();child.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['reason'],'session_changed')
        self.assertNotIn('private-sentinel',out.getvalue())

    def test_confirmed_rotation_saved_before_optional_control_failure(self):
        cookies=[SimpleNamespace(name=k,value=v,domain='.weread.qq.com',path='/')
                 for k,v in dict(wr_vid='88008800',wr_skey='new-private-sentinel').items()]
        probe=SimpleNamespace(vid=None,authenticated=True,cookies=cookies,set_cookie=lambda *_:None,verify_account=lambda:None,
                              request=lambda stage,*_:dict(books=[dict(bookId='99009900')]) if stage=='shelf' else dict(book=dict(progress=37.8)),
                              close=lambda:None,report=dict(stages=[]))
        with patch('verify_shelf_progress.SessionStore') as store,patch('verify_shelf_progress.WebSourceProbe',return_value=probe),\
                patch('verify_shelf_progress.anonymous_progress',side_effect=DisplayError('anonymous_progress_limit')),redirect_stdout(io.StringIO()) as out:
            store.return_value.load.return_value=dict(vid='88008800',cookies=dict(wr_vid='88008800',wr_skey='old-private-sentinel'))
            self.assertEqual(main(['--saved-session','--sample','1','--anonymous-control']),1)
            store.return_value.save.assert_called_once_with(probe)
        self.assertTrue(json.loads(out.getvalue())['refreshed_session_saved_to_keychain'])
        self.assertNotIn('private-sentinel',out.getvalue())


if __name__=='__main__':unittest.main()
