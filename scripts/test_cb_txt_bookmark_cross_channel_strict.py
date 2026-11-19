"""Offline prior-scope and strict readback checks."""
import contextlib
from copy import deepcopy
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from personal_upload_trial import hash_value
from test_secure_native_session import Backend
from verify_cb_txt_fixture import Receipt
import verify_cb_txt_bookmark_cross_channel_strict as verify


class StrictTrialTests(unittest.TestCase):
    def setUp(self):
        self.state=dict(phase='restored',target='CB_Synthetic42',attempt='a'*32,plan={'owner':'900000'})
        self.raw=json.dumps(dict(schema=1,owner='900000',target=self.state['target'],attempt=self.state['attempt'],plan_sha256=hash_value(self.state['plan']))).encode()
        self.receipt=Receipt(Backend());self.receipt.backend.save(self.raw);self.claim=object()
        self.journal=SimpleNamespace(read=lambda:(deepcopy(self.state),self.claim))
        self.intent=SimpleNamespace(read=lambda:(None,None));self.prior=(self.journal,self.receipt,self.intent)

    def test_default_does_not_open_credentials(self):
        with patch.object(verify,'SessionStore') as store,contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(verify.main([]),0)
        store.assert_not_called();self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def test_prior_scope_is_untouched_and_saved_may_be_cleared(self):
        saved={'vid':'900000'}
        def runner(*_args,**_kwargs):saved.clear();return {'result':'CB_TXT_BOOKMARK_CROSS_CHANNEL_VERIFIED'}
        result=verify.run(saved,None,None,{},object(),object(),object(),['synthetic'],prior=self.prior,runner=runner)
        self.assertEqual(result['result'],'CB_TXT_BOOKMARK_STRICT_CROSS_CHANNEL_VERIFIED');self.assertTrue(result['complete_web_snapshot_stable'])
        self.assertEqual(self.receipt.backend.load(),self.raw)

    def test_prior_scope_change_is_never_reported_as_success(self):
        def changed(*_args,**_kwargs):self.state['phase']='imported';return {'result':'CB_TXT_BOOKMARK_CROSS_CHANNEL_VERIFIED','native_writes':2}
        result=verify.run({'vid':'900000'},None,None,{},object(),object(),object(),['synthetic'],prior=self.prior,runner=changed)
        self.assertEqual(result['result'],'CB_TXT_BOOKMARK_STRICT_CROSS_CHANNEL_UNVERIFIED')
        self.assertFalse(result['prior_scope_unchanged']);self.assertEqual(result['native_writes'],2)

    def test_only_verified_cross_channel_becomes_strict_verified(self):
        runner=lambda *_args,**_kwargs:{'result':'CB_TXT_BOOKMARK_CROSS_CHANNEL_UNVERIFIED'}
        result=verify.run({'vid':'900000'},None,None,{},object(),object(),object(),['synthetic'],prior=self.prior,runner=runner)
        self.assertEqual(result['result'],'CB_TXT_BOOKMARK_CROSS_CHANNEL_UNVERIFIED');self.assertNotIn('complete_web_snapshot_stable',result)


if __name__=='__main__':unittest.main()
