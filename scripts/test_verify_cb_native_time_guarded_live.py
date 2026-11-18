"""The host must rehearse, claim once and independently verify in order."""
from copy import deepcopy
import contextlib,io,json,unittest
from unittest.mock import Mock,patch

from cb_native_time_bundle_preflight import Prepared
from native_time_bundle_preparation import SigningInputs
from secure_highlight_trial import Receipt
from test_cb_native_time_bundle_evidence import fixture
import verify_cb_native_time_guarded_live as task


class LiveHostTests(unittest.TestCase):
    def case(self):
        bundle,grant,report,snapshot,months,pairs=fixture()
        from cb_native_time_bundle_evidence import PreflightEvidence
        evidence=PreflightEvidence(bundle,grant,report,snapshot,months,pairs);receipt=Receipt(b'synthetic-capture')
        store=Mock();store.backend=None;store.read.return_value=(deepcopy(bundle),receipt)
        gate=Mock();gate.backend=None;gate.read.return_value=(None,None)
        audit=Mock();audit.backend=None;audit.read.return_value=(None,None)
        saved=dict(vid=bundle['plan']['owner'],cookies={'wr_vid':bundle['plan']['owner'],'wr_skey':'mock_key'})
        session=Mock();session.load.side_effect=lambda:deepcopy(saved)
        native=Mock();native.load.side_effect=lambda _owner:deepcopy(grant)
        prepared=Prepared(deepcopy(bundle),receipt,deepcopy(grant),evidence)
        return bundle,report,store,session,native,gate,audit,prepared

    def test_stages_stop_at_the_first_failure(self):
        for mode in ('success','early','consumed','dry_failed','dry_ambiguous','dry_error','attest','preflight',
                     'session','signing','denied','broker_error','missing_ack','readback_failed','readback_error','wrong_seconds'):
            with self.subTest(mode=mode):
                bundle,report,store,session,native,gate,audit,prepared=self.case();events=[]
                def make(name,value):
                    def invoke(*_args,**_kwargs):events.append(name);return value
                    return Mock(side_effect=invoke)
                dry=make('dry',dict(result='CB_NATIVE_DRY_RUN_VERIFIED',profile_removed=True,
                    dispatch_may_have_occurred=False,account_data_posts=0,authentication_posts=0,capture_and_journals_unchanged=True))
                attest=make('attest',['synthetic-worker']);preflight=make('preflight',(report,prepared))
                prepare=make('signing',SigningInputs('synthetic-guest','synthetic-config'))
                sent=dict(result='CB_NATIVE_ACKNOWLEDGED',dispatch_may_have_occurred=True,profile_removed=True,
                          account_data_posts_confirmed=1,authentication_posts=0)
                broker=make('broker',sent)
                checked=dict(result='CB_READBACK_MATCH',independent_samples=3,historical_date_matched=True,
                    positions_source_shelves_and_other_counts_unchanged=True,account_data_posts=0,
                    authentication_posts=0,seconds=bundle['plan']['seconds'])
                readback=make('readback',checked);now=report['completed_at']
                if mode=='early':now=bundle['plan']['not_before']-1
                elif mode=='consumed':gate.read.return_value=({'phase':'claimed'},Receipt(b'consumed'))
                elif mode=='dry_failed':dry=make('dry',dict(result='UNVERIFIED',dispatch_may_have_occurred=False,account_data_posts=0))
                elif mode=='dry_ambiguous':dry=make('dry',dict(result='UNVERIFIED',dispatch_may_have_occurred=True,account_data_posts=None))
                elif mode=='dry_error':dry.side_effect=RuntimeError('private failure')
                elif mode=='attest':attest.side_effect=RuntimeError('private failure')
                elif mode=='preflight':preflight=make('preflight',({'result':'UNVERIFIED'},prepared))
                elif mode=='session':native.load.side_effect=None;native.load.return_value={'vid':'different'}
                elif mode=='signing':prepare.side_effect=RuntimeError('private failure')
                elif mode=='denied':sent.update(result='UNVERIFIED',dispatch_may_have_occurred=False)
                elif mode=='broker_error':broker.side_effect=RuntimeError('private failure')
                elif mode=='missing_ack':sent['result']='UNVERIFIED'
                elif mode=='readback_failed':checked['result']='UNVERIFIED'
                elif mode=='readback_error':readback.side_effect=RuntimeError('private failure')
                elif mode=='wrong_seconds':checked['seconds']+=1
                result=task.run(store,session,native,gate,audit,clock=lambda:now,attest=attest,rehearsal=dry,
                                preflight=preflight,prepare=prepare,broker=broker,readback=readback)
                if mode=='success':
                    self.assertEqual(result['result'],'CB_NATIVE_TRANSFER_READBACK_MATCH')
                    self.assertEqual(events,['dry','attest','preflight','signing','broker','readback'])
                    self.assertTrue(broker.call_args.kwargs['armed']);self.assertEqual(result['account_data_posts'],1)
                else:self.assertNotEqual(result['result'],'CB_NATIVE_TRANSFER_READBACK_MATCH')
                if mode=='early':
                    self.assertEqual(result['result'],'NOT_YET_HISTORICAL');gate.read.assert_not_called()
                    session.load.assert_not_called();dry.assert_not_called()
                if mode in ('early','consumed','dry_failed','dry_ambiguous','dry_error','attest','preflight','session','signing'):
                    broker.assert_not_called();readback.assert_not_called()
                if mode in ('denied','broker_error','missing_ack'):readback.assert_not_called()
                if mode in ('dry_ambiguous','dry_error','broker_error','missing_ack'):
                    self.assertIsNone(result['account_data_posts']);self.assertTrue(result['dispatch_may_have_occurred'])
                if mode in ('readback_failed','readback_error','wrong_seconds'):
                    self.assertEqual(result['result'],'CB_NATIVE_ACKNOWLEDGED_READBACK_UNVERIFIED')
                    self.assertEqual(result['account_data_posts'],1)
                self.assertNotIn('private failure',json.dumps(result))

    def test_real_scope_rejects_overrides_before_reading_capture(self):
        class FakeMac:pass
        store=Mock();store.backend=FakeMac();gate=Mock();gate.backend=None;audit=Mock();audit.backend=None
        with patch.object(task,'MacKeychain',FakeMac):
            result=task.run(store,Mock(),Mock(),gate,audit,clock=lambda:1)
        self.assertEqual(result['result'],'UNVERIFIED');store.read.assert_not_called()

    def test_no_argument_is_offline(self):
        with patch.object(task,'capture_store') as store,contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]),0)
        store.assert_not_called();self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def test_live_attestation_only_replaces_the_expected_worker(self):
        worker='scripts/run_cb_native_time_guarded_dry.py'
        with patch.object(task,'trusted_command',return_value=['docker','exec',worker,'--candidate','candidate']):
            self.assertEqual(task.trusted_live_command(),['docker','exec','scripts/run_cb_native_time_guarded_live.py',
                                                          '--candidate','candidate'])
        for command in (['docker','exec','other'],['docker',worker,worker]):
            with patch.object(task,'trusted_command',return_value=command):
                with self.assertRaises(ValueError):task.trusted_live_command()


if __name__=='__main__':unittest.main()
