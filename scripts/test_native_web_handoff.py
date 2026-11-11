"""A rotated Web cookie must replace the stale native handoff snapshot."""
from copy import deepcopy
from types import SimpleNamespace
import unittest
from unittest.mock import Mock,patch
from secure_weread_session import StoreError
from selection_trial_probe import prepare_web_handoff


class HandoffTests(unittest.TestCase):
    def fixture(self):
        saved=dict(vid='900000',cookies=dict(wr_vid='900000',wr_skey='synthetic-old-cookie'))
        fresh=dict(vid='900000',cookies=dict(wr_vid='900000',wr_skey='synthetic-new-cookie'))
        source=Mock();source.plan.bound=dict(owner=saved['vid'],source_hash='a'*64)
        source.payload=dict(cookies=deepcopy(saved['cookies']),selection_preview={'unchanged':'source-bound'})
        source.web.cookies=[SimpleNamespace(name=k,value=v,domain='.weread.qq.com',path='/') for k,v in fresh['cookies'].items()]
        return saved,fresh,source

    def test_new_verified_cookie_is_saved_read_back_and_copied_before_native_launch(self):
        saved,fresh,source=self.fixture();store=Mock();store.load.return_value=fresh
        before=deepcopy(source.plan.bound)
        with patch('verify_translation_preflight.save_refreshed_web_session',return_value=True) as persist:
            result=prepare_web_handoff(store,saved,source)
        source.web.verify_account.assert_called_once();persist.assert_called_once_with(store,saved,source.web)
        self.assertEqual(source.payload['cookies'],fresh['cookies']);self.assertNotEqual(source.payload['cookies'],saved['cookies'])
        self.assertEqual(source.plan.bound,before);self.assertEqual(source.current.call_count,2)
        result['cookies']['wr_skey']='later external change'
        self.assertNotEqual(source.payload['cookies']['wr_skey'],result['cookies']['wr_skey'])

    def test_different_owner_is_rejected_before_saving_or_handoff(self):
        saved,_fresh,source=self.fixture();source.web.cookies[0].value='900001'
        with patch('verify_translation_preflight.save_refreshed_web_session') as persist,self.assertRaises(ValueError):
            prepare_web_handoff(Mock(),saved,source)
        persist.assert_not_called();self.assertEqual(source.payload['cookies'],saved['cookies'])

    def test_failed_save_or_wrong_readback_keeps_old_payload(self):
        for mode in ('save','readback'):
            saved,fresh,source=self.fixture();store=Mock();store.load.return_value=saved
            with patch('verify_translation_preflight.save_refreshed_web_session',side_effect=StoreError('readback') if mode=='save' else None,return_value=True),self.assertRaises((StoreError,ValueError)):
                prepare_web_handoff(store,saved,source)
            self.assertEqual(source.payload['cookies'],saved['cookies']);self.assertEqual(source.current.call_count,1)
            self.assertNotEqual(fresh['cookies'],source.payload['cookies'])

    def test_concurrent_session_replacement_is_not_adopted_without_rotation(self):
        saved,fresh,source=self.fixture();source.web.cookies=[SimpleNamespace(name=k,value=v,domain='.weread.qq.com',path='/') for k,v in saved['cookies'].items()]
        store=Mock();store.load.return_value=fresh
        with patch('verify_translation_preflight.save_refreshed_web_session',return_value=False),self.assertRaises(ValueError):prepare_web_handoff(store,saved,source)
        self.assertEqual(source.payload['cookies'],saved['cookies'])


if __name__=='__main__':unittest.main()
