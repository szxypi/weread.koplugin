"""The independent rehearsal cannot dispatch or overwrite old journals."""
from copy import deepcopy
import unittest
from unittest.mock import Mock

from native_time_bundle_preparation import SigningInputs
from secure_highlight_trial import Receipt
from test_native_time_independent_audit import fixture
import verify_independent_time_dry as task


class Binding:
    def __init__(self,session,native):
        self._saved=deepcopy(session.saved);self._grant=deepcopy(native.grant);self.valid=True
    def __call__(self):return self.valid
    def close(self):self._saved.clear();self._grant.clear()


class DryTests(unittest.TestCase):
    def setup_case(self):
        bundle,grant,_body,now,_before,proof,gate,audit,_samples,_observations=fixture()
        store=Mock();store.read.return_value=(bundle,Receipt(b'synthetic'))
        session=Mock();session.saved={'vid':bundle['plan']['owner'],'cookies':{'wr_vid':bundle['plan']['owner'],'wr_skey':'mock_key'}}
        native=Mock();native.grant=grant
        olds=[Mock(),Mock(),Mock()]
        for old in olds:old.read.return_value=(None,None)
        signer=Mock();signer.return_value.read.return_value=SigningInputs('guest','config')
        broker=Mock(return_value={'result':'INDEPENDENT_NATIVE_DRY_RUN_VERIFIED','profile_removed':True,
            'dispatch_may_have_occurred':False,'account_data_posts_confirmed':0,'authentication_posts':0})
        args=(store,session,native,gate,audit,*olds)
        options=dict(clock=lambda:now,attest=lambda:['worker'],preflight=lambda *_a,**_k:proof,
                     signer=signer,broker=broker,binding_type=Binding)
        return args,options,broker,signer,proof

    def test_dry_requires_zero_send_and_unchanged_journals(self):
        args,options,broker,_signer,_proof=self.setup_case()
        result=task.run(*args,**options)
        self.assertEqual(result['result'],'INDEPENDENT_NATIVE_DRY_RUN_VERIFIED')
        self.assertEqual(result['account_data_posts'],0);self.assertFalse(result['dispatch_may_have_occurred'])
        self.assertTrue(result['capture_and_all_journals_unchanged']);self.assertFalse(result['real_accounting_verified'])
        self.assertFalse(broker.call_args.kwargs['armed'])

    def test_blocked_or_unconfirmed_conditions_never_authorize_send(self):
        for mode in ('preflight','signing','capture','old','result','maybe_sent'):
            args,options,broker,signer,proof=self.setup_case()
            if mode=='preflight':options['preflight']=lambda *_a,**_k: {'result':'UNVERIFIED'}
            elif mode=='signing':signer.return_value.read.return_value='invalid'
            elif mode=='capture':args[0].read.side_effect=[args[0].read.return_value,(None,None)]
            elif mode=='old':args[5].read.side_effect=[(None,None),('changed',None)]
            elif mode=='result':broker.return_value['profile_removed']=False
            else:broker.return_value['dispatch_may_have_occurred']=True
            with self.subTest(mode=mode):
                result=task.run(*args,**options);self.assertEqual(result['result'],'UNVERIFIED')
                self.assertFalse(result['real_accounting_verified'])
                if mode in ('preflight','signing','capture','old'):broker.assert_not_called()
                if mode=='maybe_sent':self.assertTrue(result['dispatch_may_have_occurred']);self.assertIsNone(result['account_data_posts'])


if __name__=='__main__':unittest.main()
