"""Synthetic display contract only; never opens the real Keychain or network."""
from contextlib import redirect_stdout
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from verify_shelf_progress import DisplayError,main,parse


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
        probe=SimpleNamespace(vid=None,cookies=cookies,set_cookie=lambda *_:None,verify_account=lambda:None,
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


if __name__=='__main__':unittest.main()
