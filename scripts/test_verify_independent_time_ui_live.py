"""The real-menu coordinator never retries and reports uncertain writes conservatively."""
from copy import deepcopy
import unittest
from unittest.mock import Mock,patch

from native_time_bundle_preparation import SigningInputs
from secure_highlight_trial import Receipt
from test_native_time_independent_audit import fixture
from test_verify_independent_time_dry import Binding
import verify_independent_time_ui_live as task


class LiveTests(unittest.TestCase):
    def setup_case(self,mode='match'):
        bundle,grant,body,now,_before,proof,gate,audit,_samples,_observations=fixture()
        store=Mock();store.read.return_value=(bundle,Receipt(b'synthetic'))
        session=Mock();session.saved={'vid':bundle['plan']['owner'],'cookies':{'wr_vid':bundle['plan']['owner'],'wr_skey':'mock_key'}}
        native=Mock();native.grant=grant
        olds=[Mock(),Mock(),Mock()]
        for old in olds:old.read.return_value=(None,None)
        dry=Mock(return_value={'result':'INDEPENDENT_NATIVE_MENU_DRY_VERIFIED','profile_removed':True,
            'dispatch_may_have_occurred':False,'account_data_posts':0,'authentication_posts':0,
            'capture_and_all_journals_unchanged':True})
        signer=Mock();signer.return_value.read.return_value=SigningInputs('synthetic-guest','synthetic-config')
        def transfer(prepared,_inputs,_cookies,_store,gate,audit,_binding,_command,*,armed):
            self.assertTrue(armed)
            if mode=='raises':raise RuntimeError('synthetic private error')
            if mode=='not_dispatched':return {'dispatch_may_have_occurred':False}
            reservation=gate.reserve(prepared.bundle,prepared.grant);audit.seal(prepared.bundle,prepared.grant,gate,prepared.evidence)
            claimed=gate.claim(reservation,prepared.bundle,prepared.grant,body,'synthetic-guest','synthetic-config')
            if mode!='missing_ack':gate.acknowledge(claimed,{'succ':1})
            if mode in ('missing_ack','worker_failed'):
                return {'result':'UNVERIFIED','dispatch_may_have_occurred':True}
            return {'result':'INDEPENDENT_NATIVE_ACKNOWLEDGED','dispatch_may_have_occurred':True,
                    'profile_removed':True,'account_data_posts_confirmed':1,'authentication_posts':0}
        broker=Mock(side_effect=transfer)
        readback=Mock(return_value={'result':'READBACK_MATCH','independent_samples':3,'other_state_exact':True,
                                    'full_shelf_exact':True,'account_data_posts':0,'authentication_posts':0})
        if mode=='partial':readback.return_value={'result':'READBACK_PARTIAL','independent_samples':3,
            'accounting_and_core_state_exact':True,'full_shelf_exact':False,'account_data_posts':0,'authentication_posts':0,
            'component_diagnosis_available':False}
        if mode=='readback_error':readback.side_effect=ValueError('private synthetic detail')
        args=(store,session,native,gate,audit,*olds)
        options=dict(clock=lambda:now,attest=lambda:['synthetic-worker'],rehearsal=dry,
                     preflight=lambda *_a,**_k:proof,signer=signer,broker=broker,readback=readback,binding_type=Binding)
        return args,options,dry,broker,readback

    def test_success_requires_native_receipt_and_independent_readback(self):
        args,options,dry,broker,readback=self.setup_case()
        result=task.run(*args,**options)
        self.assertEqual(result['result'],'INDEPENDENT_MENU_READBACK_MATCH')
        self.assertEqual(result['account_data_posts'],1);self.assertTrue(result['independent_readback'])
        self.assertTrue(result['menu_confirmed']);self.assertFalse(result['real_accounting_verified'])
        self.assertTrue(dry.call_args.kwargs['ui']);self.assertTrue(dry.call_args.kwargs['live_worker'])
        self.assertEqual(broker.call_count,1);self.assertEqual(readback.call_count,1)
        self.assertEqual(args[3].read()[0]['phase'],'acknowledged')
        second=task.run(*args,**options)
        self.assertEqual(second['result'],'UNVERIFIED');self.assertEqual(broker.call_count,1)

    def test_failures_keep_one_shot_and_report_unknown_or_partial_honestly(self):
        for mode in ('missing_ack','worker_failed','raises','not_dispatched','partial','readback_error'):
            args,options,_dry,broker,readback=self.setup_case(mode)
            with self.subTest(mode=mode):
                result=task.run(*args,**options)
                self.assertEqual(broker.call_count,1)
                if mode=='not_dispatched':
                    self.assertEqual(result['account_data_posts'],0);self.assertFalse(result['dispatch_may_have_occurred'])
                    readback.assert_not_called()
                elif mode in ('raises','missing_ack'):
                    self.assertIsNone(result['account_data_posts']);self.assertTrue(result['dispatch_may_have_occurred'])
                    readback.assert_not_called()
                    if mode=='missing_ack':self.assertEqual(args[3].read()[0]['phase'],'claimed')
                elif mode=='worker_failed':
                    self.assertEqual(result['result'],'INDEPENDENT_READBACK_MATCH_MENU_UNVERIFIED')
                    self.assertFalse(result['menu_confirmed']);self.assertEqual(result['account_data_posts'],1)
                else:
                    self.assertEqual(result['result'],'INDEPENDENT_MENU_ACKNOWLEDGED_READBACK_UNVERIFIED')
                    self.assertEqual(result['account_data_posts'],1);self.assertFalse(result['independent_readback'])
                    if mode=='partial':self.assertTrue(result['accounting_and_core_state_observed'])
                self.assertNotIn('private synthetic detail',repr(result))

    def test_preflight_failures_never_launch_worker(self):
        for mode in ('dry','dry_uncertain','proof','signing','legacy_changed'):
            args,options,dry,broker,_readback=self.setup_case()
            if mode=='dry':dry.return_value['result']='UNVERIFIED'
            elif mode=='dry_uncertain':dry.return_value.update(result='UNVERIFIED',dispatch_may_have_occurred=True,account_data_posts=None)
            elif mode=='proof':options['preflight']=lambda *_a,**_k:None
            elif mode=='signing':options['signer'].return_value.read.return_value='invalid'
            else:args[5].read.side_effect=[(None,None),('changed',None)]
            with self.subTest(mode=mode):
                result=task.run(*args,**options);self.assertEqual(result['result'],'UNVERIFIED');broker.assert_not_called()
                if mode=='dry_uncertain':self.assertIsNone(result['account_data_posts']);self.assertTrue(result['dispatch_may_have_occurred'])
                else:self.assertEqual(result['account_data_posts'],0)

    def test_real_scope_rejects_injected_dependencies_before_access(self):
        class FakeMac:pass
        args,options,_dry,broker,_readback=self.setup_case();args[0].backend=FakeMac()
        with patch.object(task,'MacKeychain',FakeMac):result=task.run(*args,**options)
        self.assertEqual(result['reason'],'independent_live/override');args[0].read.assert_not_called();broker.assert_not_called()

    def test_legacy_journal_change_after_receipt_never_reports_full_match(self):
        args,options,_dry,_broker,readback=self.setup_case()
        value=readback.return_value
        def changed(**_kwargs):
            args[5].read.return_value=('changed',None)
            return value
        readback.side_effect=changed
        result=task.run(*args,**options)
        self.assertEqual(result['result'],'INDEPENDENT_MENU_ACKNOWLEDGED_READBACK_UNVERIFIED')
        self.assertFalse(result['independent_readback']);self.assertEqual(result['account_data_posts'],1)

    def test_default_entrypoint_is_offline(self):
        with patch.object(task,'capture_store') as store,patch('builtins.print'):
            self.assertEqual(task.main([]),0)
        store.assert_not_called()


if __name__=='__main__':unittest.main()
