"""Fresh rehearsal requires the exact saved capture and cannot send."""
from copy import deepcopy
from contextlib import redirect_stdout
import io,json,unittest
from unittest.mock import Mock,patch

from native_time_bundle_preparation import SigningInputs
from secure_highlight_trial import Receipt
from test_native_time_bundle_evidence import fresh_fixture,synthetic_scope
from test_native_time_bundle_gate import gate
import verify_native_time_fresh_dry as task


class DryTests(unittest.TestCase):
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
        self.broker=Mock(return_value=dict(result='NATIVE_FRESH_DRY_RUN_VERIFIED',profile_removed=True,
                    dispatch_may_have_occurred=False,account_data_posts_confirmed=0,authentication_posts=0))

    def run_case(self):
        return task.run(self.store,self.session,self.native,self.gate,self.audit,self.legacy,clock=lambda:self.now,
                        attest=self.attest,preflight=self.preflight,web_factory=lambda:self.web,signer=lambda *_:self.signer,
                        broker=self.broker,trial_factory=lambda bundle,_current:lambda:synthetic_scope(bundle),save_web=lambda *_:False)

    def test_exact_preflight_and_dry_broker_leave_all_records_unchanged(self):
        result=self.run_case()
        self.assertEqual(result['result'],'NATIVE_FRESH_DRY_RUN_VERIFIED');self.assertEqual(result['account_data_posts'],0)
        self.assertFalse(result['dispatch_may_have_occurred']);self.assertTrue(result['capture_and_journals_unchanged'])
        self.assertFalse(self.broker.call_args.kwargs['armed']);self.assertEqual(self.gate.read(),(None,None))
        self.web.close.assert_called_once()

    def test_consumed_scope_and_uncertain_broker_never_report_success(self):
        self.legacy.read.return_value=({'phase':'baseline'},Receipt(b'old'))
        result=self.run_case();self.assertEqual(result['reason'],'fresh_dry/consumed');self.attest.assert_not_called()
        self.setUp();self.broker.return_value={'result':'UNVERIFIED'};result=self.run_case()
        self.assertEqual(result['result'],'UNVERIFIED');self.assertTrue(result['dispatch_may_have_occurred'])
        self.assertIsNone(result['account_data_posts'])

    def test_foreign_preflight_or_account_never_reaches_broker(self):
        self.saved['vid']='900002';result=self.run_case()
        self.assertEqual(result['reason'],'fresh_dry/session');self.broker.assert_not_called()
        self.setUp();self.preflight.return_value='not private evidence';self.assertEqual(self.run_case()['result'],'UNVERIFIED')
        self.broker.assert_not_called();self.assertEqual(self.gate.read(),(None,None))

    def test_default_cli_remains_offline(self):
        with patch.object(task,'CaptureBundleStore') as capture,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]),0)
        capture.assert_not_called();self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def test_real_scope_rejects_injected_transport(self):
        class FakeMac:pass
        self.store.backend=FakeMac()
        with patch.object(task,'MacKeychain',FakeMac):result=self.run_case()
        self.assertEqual(result['reason'],'fresh_dry/override');self.attest.assert_not_called();self.preflight.assert_not_called()


if __name__=='__main__':unittest.main()
