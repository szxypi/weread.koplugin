"""Saved-account dry run is early-gated and cannot arm the native worker."""
from copy import deepcopy
import contextlib,io,json,tempfile,unittest
from pathlib import Path
from unittest.mock import Mock,patch

from cb_native_time_bundle_preflight import Prepared
from native_time_bundle_preparation import SigningInputs
from secure_highlight_trial import Receipt
from test_cb_native_time_bundle_evidence import fixture
import verify_cb_native_time_guarded_dry as task


class DryHostTests(unittest.TestCase):
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
    def test_before_boundary_never_opens_account_or_container(self):
        bundle,_report,store,session,native,gate,audit,_prepared=self.case();attest=Mock();preflight=Mock();prepare=Mock();broker=Mock()
        result=task.run(store,session,native,gate,audit,clock=lambda:bundle['plan']['not_before']-1,
                        attest=attest,preflight=preflight,prepare=prepare,broker=broker)
        self.assertEqual(result['result'],'NOT_YET_HISTORICAL');self.assertEqual(result['account_data_posts'],0)
        for mock in (attest,preflight,prepare,broker,session.load,native.load,gate.read,audit.read):mock.assert_not_called()
    def test_full_dry_flow_and_changes_fail_closed(self):
        for mode in ('success','preflight','session','receipt','broker','broker_error'):
            with self.subTest(mode=mode):
                bundle,report,store,session,native,gate,audit,prepared=self.case()
                if mode=='receipt':prepared.receipt=Receipt(b'changed')
                if mode=='session':native.load.return_value={'vid':'other'};native.load.side_effect=None
                attest=Mock(return_value=['trusted-synthetic-worker'])
                preflight=Mock(return_value=({'result':'UNVERIFIED'} if mode=='preflight' else report,prepared))
                prepare=Mock(return_value=SigningInputs('synthetic-guest','synthetic-config'))
                checked=dict(result='CB_NATIVE_DRY_RUN_VERIFIED',profile_removed=True,dispatch_may_have_occurred=False,
                             account_data_posts_confirmed=0,authentication_posts=0)
                if mode=='broker':checked['dispatch_may_have_occurred']=True
                broker=Mock(return_value=checked)
                if mode=='broker_error':broker.side_effect=RuntimeError('synthetic failure')
                result=task.run(store,session,native,gate,audit,clock=lambda:report['completed_at'],
                                attest=attest,preflight=preflight,prepare=prepare,broker=broker)
                self.assertEqual(result['result'],'CB_NATIVE_DRY_RUN_VERIFIED' if mode=='success' else 'UNVERIFIED')
                if mode in ('success','broker','broker_error'):self.assertFalse(broker.call_args.kwargs['armed'])
                else:broker.assert_not_called()
                self.assertEqual(result['account_data_posts'],None if mode in ('broker','broker_error') else 0)
                self.assertEqual(result['dispatch_may_have_occurred'],mode in ('broker','broker_error'))
    def test_real_scopes_cannot_override_time_or_transport(self):
        class FakeMac:pass
        store=Mock();store.backend=FakeMac();gate=Mock();gate.backend=None;audit=Mock();audit.backend=None
        with patch.object(task,'MacKeychain',FakeMac):
            result=task.run(store,Mock(),Mock(),gate,audit,clock=lambda:1)
        self.assertEqual(result['result'],'UNVERIFIED');store.read.assert_not_called()
    def test_offline_cli_does_not_instantiate_stores(self):
        with patch.object(task,'capture_store') as store,contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]),0)
        store.assert_not_called();self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')
    def test_only_expected_readonly_source_mount_and_candidate_are_accepted(self):
        for mode in ('valid','source_writable','wrong_source','wrong_validation','candidate_failed','candidate_path','stopped'):
            with self.subTest(mode=mode),tempfile.TemporaryDirectory() as directory:
                parent=Path(directory);source=parent/'repo';(source/'scripts').mkdir(parents=True);validation=parent/'.validation';validation.mkdir()
                mounts=[{'Type':'bind','Source':str(source),'Destination':'/source','RW':False},
                        {'Type':'bind','Source':str(validation),'Destination':'/validation','RW':True}]
                if mode=='source_writable':mounts[0]['RW']=True
                if mode=='wrong_source':mounts[0]['Source']=str(parent)
                if mode=='wrong_validation':mounts[1]['Source']=str(parent)
                running=mode!='stopped';identifier='a'*64
                inspection=Mock(stdout=(json.dumps(running)+' '+json.dumps(identifier)+' '+json.dumps(mounts)).encode())
                candidate=Mock(stdout=json.dumps({'result':'UNVERIFIED'} if mode=='candidate_failed' else {
                    'result':'CANDIDATE_READY','files':9,'path':'/validation/'+('evil.zip' if mode=='candidate_path'
                        else 'cb-dry-candidate-'+'b'*64+'.zip')}).encode())
                with patch.object(task,'__file__',str(source/'scripts'/'dummy.py')),patch.object(task.shutil,'which',return_value='/usr/bin/docker'),\
                     patch.object(task.subprocess,'run',side_effect=[inspection,candidate]):
                    if mode=='valid':
                        command=task.trusted_command();self.assertEqual(command[0],'/usr/bin/docker');self.assertIn(identifier,command)
                    else:
                        with self.assertRaises(ValueError):task.trusted_command()


if __name__=='__main__':unittest.main()
