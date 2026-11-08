"""Synthetic Web shelf boundaries. No network, credentials or Keychain access."""
from contextlib import redirect_stdout
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from web_shelf_contract import ShelfError, identity, main, normalize


def snapshot():
    return dict(books=[dict(bookId=900001,title='Synthetic book',author='Synthetic author',version=800,
                            bookVersion=99,readUpdateTime=100,secret=1)],
                archive=[dict(archiveId=1,name='Synthetic group',bookIds=[900001]),dict(bookIds=[])])


class ShelfContractTests(unittest.TestCase):
    def test_bounded_display_projection_keeps_version_observational(self):
        value=normalize(snapshot())
        self.assertEqual(value['books'][0],dict(bookId='900001',title='Synthetic book',author='Synthetic author',
                                               readUpdateTime=100,_web_shelf_version=800,secret=1))
        self.assertEqual(value['archive'][0]['bookIds'],['900001'])
        self.assertNotIn('bookVersion',value['books'][0])

    def test_invalid_shapes_and_ambiguous_identity_fail_closed(self):
        for value in ({},dict(books={}),dict(books=[],archive={}),dict(books=[{}]),
                      dict(books=[snapshot()['books'][0]]*2),dict(books=[],archive=[dict(bookIds={})]),
                      dict(books=[],archive=[dict(bookIds=[False])])):
            with self.assertRaisesRegex(ShelfError,'^web_shelf_invalid$'):
                normalize(value)
        for value in (False,0,-1,1.1,float('nan'),float('inf'),2**53,None,'a\nb'):
            self.assertIsNone(identity(value))

    def test_collection_and_string_limits(self):
        for value in (dict(books=[{}]*5001),dict(books=[],archive=[{}]*1001),
                      dict(books=[],archive=[dict(bookIds=['1']*5001)]),
                      dict(books=[dict(bookId='1',title='中'*1366)])):
            with self.assertRaises(ShelfError):normalize(value)

    def test_default_mode_never_loads_credentials_or_requests_network(self):
        with patch('secure_weread_session.SessionStore') as store, patch('verify_web_source_progress.WebSourceProbe') as probe, redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main([]),0)
        store.assert_not_called();probe.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_saved_mode_report_contains_only_counts_and_bools(self):
        private=snapshot();private['books'][0]['title']='PRIVATE-SENTINEL-TITLE'
        probe=SimpleNamespace(vid=None,set_cookie=lambda *_:None,verify_account=lambda:None,
                              request=lambda *_:private,close=lambda:None,report=dict(stages=[dict(stage='account',status=200)]))
        with patch('secure_weread_session.SessionStore') as store, patch('verify_web_source_progress.WebSourceProbe',return_value=probe), redirect_stdout(io.StringIO()) as out:
            store.return_value.load.return_value=dict(vid='900000',cookies=dict(wr_skey='PRIVATE-SENTINEL-COOKIE'))
            self.assertEqual(main(['--saved-session']),0)
        self.assertNotIn('PRIVATE-SENTINEL',out.getvalue())
        self.assertEqual(json.loads(out.getvalue())['book_count'],1)


if __name__=='__main__':
    unittest.main()
