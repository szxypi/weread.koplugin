"""One real-account orchestration cannot skip rehearsal or replay ambiguity."""
from copy import deepcopy
from contextlib import redirect_stdout
import io,json,unittest
from unittest.mock import Mock,patch

from native_time_bundle_preparation import SigningInputs
from secure_highlight_trial import Receipt
from test_native_time_bundle_evidence import fresh_fixture,synthetic_scope
from test_native_time_bundle_gate import fixture,gate
import verify_native_time_fresh_live as task


class LiveTests(unittest.TestCase):
    def setUp(self):
        self.bundle,self.grant,_before,_report,self.now,_pairs,_shelves,self.evidence=fresh_fixture()
        self.receipt=Receipt(b'synthetic');self.store=Mock();self.store.backend=object()
        self.store.read.return_value=(self.bundle,self.receipt);self.gate=gate(self.now)
        self.audit=Mock();self.audit.backend=object();self.audit.read.return_value=(None,None)
        self.legacy=Mock();self.legacy.backend=object();self.legacy.read.return_value=(None,None)
        self.saved={'vid':self.bundle['plan']['owner'],'cookies':{'wr_vid':self.bundle['plan']['owner'],'wr_skey':'mock_key'}}
        self.session=Mock();self.session.load.side_effect=lambda:deepcopy(self.saved)
        self.native=Mock();self.native.load.side_effect=lambda _owner:deepcopy(self.grant)
        self.web=Mock();self.web.shards={};self.web._time_catalog_pair=[]
        self.preflight=Mock(return_value=self.evidence);self.attest=Mock(return_value=['synthetic-worker'])
        self.signer=Mock();self.signer.read.return_value=SigningInputs('synthetic-guest','synthetic-config')
        self.dry=Mock(return_value=dict(result='NATIVE_FRESH_DRY_RUN_VERIFIED',profile_removed=True,
                     dispatch_may_have_occurred=False,account_data_posts=0,authentication_posts=0,capture_and_journals_unchanged=True))
        def acknowledge(*_args,**_kwargs):
            _b,_g,body,_n=fixture();reserved=self.gate.reserve(self.bundle,self.grant)
            claim=self.gate.claim(reserved,self.bundle,self.grant,body,'synthetic-guest','synthetic-config')
            self.gate.acknowledge(claim,{'succ':1})
            return dict(result='NATIVE_FRESH_ACKNOWLEDGED',profile_removed=True,dispatch_may_have_occurred=True,
                        account_data_posts_confirmed=1,authentication_posts=0)
        self.broker=Mock(side_effect=acknowledge)
        self.audit.inspect.side_effect=lambda *_: ({},Receipt(b'audit'),*self.gate.read())
        self.readback=Mock(return_value=dict(result='READBACK_MATCH',independent_samples=3,other_state_exact=True,
                                             account_data_posts=0,authentication_posts=0))

    def run_case(self):
        return task.run(self.store,self.session,self.native,self.gate,self.audit,self.legacy,clock=lambda:self.now,
                        attest=self.attest,rehearsal=self.dry,preflight=self.preflight,web_factory=lambda:self.web,
                        signer=lambda *_:self.signer,broker=self.broker,trial_factory=lambda bundle,_current:lambda:synthetic_scope(bundle),
                        readback=self.readback,save_web=lambda *_:False)

    def test_rehearsal_claim_ack_and_three_readbacks_are_all_required(self):
        result=self.run_case();self.assertEqual(result['result'],'NATIVE_FRESH_TRANSFER_READBACK_MATCH')
        self.assertEqual(result['account_data_posts'],1);self.assertTrue(result['independent_readback'])
        self.assertFalse(result['real_accounting_verified']);self.assertEqual(result['seconds'],6)
        self.assertTrue(self.broker.call_args.kwargs['armed']);self.broker.assert_called_once();self.readback.assert_called_once()
        self.assertEqual(self.gate.read()[0]['phase'],'acknowledged')

    def test_ambiguous_rehearsal_or_broker_never_retries(self):
        self.dry.return_value={'result':'UNVERIFIED'};result=self.run_case()
        self.assertEqual(result['reason'],'fresh_live/rehearsal');self.assertTrue(result['dispatch_may_have_occurred'])
        self.assertIsNone(result['account_data_posts']);self.attest.assert_not_called();self.broker.assert_not_called()
        self.setUp();self.broker.side_effect=None;self.broker.return_value={'result':'UNVERIFIED','dispatch_may_have_occurred':True}
        result=self.run_case();self.assertEqual(result['reason'],'fresh_live/dispatch');self.assertIsNone(result['account_data_posts'])
        self.broker.assert_called_once();self.readback.assert_not_called()

    def test_acknowledged_but_changed_readback_is_not_called_verified(self):
        self.readback.return_value={'result':'UNVERIFIED'};result=self.run_case()
        self.assertEqual(result['result'],'NATIVE_FRESH_ACKNOWLEDGED_READBACK_UNVERIFIED')
        self.assertEqual(result['account_data_posts'],1);self.assertFalse(result['independent_readback'])
        self.assertFalse(result['real_accounting_verified']);self.broker.assert_called_once()

    def test_partial_readback_preserves_evidence_without_claiming_full_success(self):
        self.readback.return_value=dict(result='READBACK_PARTIAL',independent_samples=3,accounting_and_core_state_exact=True,
            full_shelf_exact=False,account_data_posts=0,authentication_posts=0)
        result=self.run_case()
        self.assertEqual(result['result'],'NATIVE_FRESH_ACKNOWLEDGED_READBACK_UNVERIFIED')
        self.assertTrue(result['accounting_and_core_state_observed']);self.assertFalse(result['full_shelf_exact'])
        self.assertFalse(result['independent_readback']);self.assertFalse(result['real_accounting_verified'])
        self.broker.assert_called_once()

    def test_missing_durable_ack_is_never_called_verified(self):
        self.broker.side_effect=None;self.broker.return_value=dict(result='NATIVE_FRESH_ACKNOWLEDGED',profile_removed=True,
                   dispatch_may_have_occurred=True,account_data_posts_confirmed=1,authentication_posts=0)
        self.audit.inspect.return_value=({},None,{'phase':'prepared'},None);self.audit.inspect.side_effect=None
        result=self.run_case();self.assertEqual(result['reason'],'fresh_live/dispatch_state')
        self.assertEqual(result['result'],'NATIVE_FRESH_ACKNOWLEDGED_READBACK_UNVERIFIED');self.readback.assert_not_called()

    def test_default_cli_is_offline_and_real_scope_rejects_override(self):
        with patch.object(task,'CaptureBundleStore') as capture,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]),0)
        capture.assert_not_called();self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')
        class FakeMac:pass
        self.store.backend=FakeMac()
        with patch.object(task,'MacKeychain',FakeMac):result=self.run_case()
        self.assertEqual(result['reason'],'fresh_live/override');self.dry.assert_not_called()


if __name__=='__main__':unittest.main()
