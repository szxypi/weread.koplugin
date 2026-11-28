import unittest
import json
from copy import deepcopy
from functools import partial
from unittest.mock import patch

from cloud_group_fixture import Journal
from native_direct_time_trial_store import Intent
from cloud_group_contract import project
from shelf_import_cleanup_diagnostic import audit, bind_audit, compare, execute, fingerprints
from synthetic_format_trial import TargetReceipt
from test_personal_upload_trial import FakeProbe, TARGET
from test_secure_native_session import Backend, credentials
from verify_synthetic_epub_upload import run as upload


class DiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.grant=credentials();self.saved={'vid':self.grant['vid'],'cookies':{'synthetic':'cookie'}}
        self.journal=Journal(Backend());self.receipt=TargetReceipt('epub',backend=Backend(),scope='group-fixture')
        self.baseline=Intent(backend=Backend());self.probe=FakeProbe();self.mode='normal';owner=self
        class Store:
            def load(self,*_args):return deepcopy(owner.grant)
        class Session:
            def load(self):return deepcopy(owner.saved)
        class Reader:
            def request(self,*_args,**_kwargs):return deepcopy(owner.probe.state)
        self.store=Store();self.native=Reader();self.web=Reader()
        self.patch=patch('shelf_import_cleanup_diagnostic.SessionStore',Session);self.patch.start();self.addCleanup(self.patch.stop)
        old_cleanup=self.probe.cleanup
        def cleanup(grant,receipt):
            result=old_cleanup(grant,receipt)
            if self.mode=='group_update':self.probe.state['archive'][0]['updateTime']=123
            if self.mode=='album_update':self.probe.state['albums']=[{'albumId':'synthetic','updateTime':3}]
            return result
        self.probe.cleanup=cleanup
    def run_case(self,*,apply=True,protected=None):
        return execute(self.saved,self.store,self.web,self.journal,self.receipt,self.baseline,protected or set(),apply=apply,
            native=self.native,upload_probe=self.probe,uploader=partial(upload,sleep=lambda _d:None,now=lambda:1000),
            content_reader=lambda _saved,_target:True,pending=lambda:True)
    def test_normal_import_cleanup_is_once_only(self):
        result=self.run_case();self.assertEqual(result['result'],'RESTORED_FULL')
        self.assertTrue(result['precleanup_full_shelf_matches']);self.assertTrue(result['fixture_absent_both_channels'])
        self.assertEqual(self.probe.attempts['cleanup'],1);self.assertEqual(self.run_case()['result'],'UNVERIFIED')
        self.assertEqual(self.probe.attempts['cleanup'],1)
    def test_audit_binds_original_records_to_same_device_across_renewal(self):
        self.assertEqual(self.run_case()['result'],'RESTORED_FULL');binding=Backend()
        bind_audit(self.saved,self.grant,self.journal,self.receipt,self.baseline,set(),binding)
        self.grant['accessToken']='synthetic-new-access'
        with self.assertRaises(ValueError):audit(self.saved,self.store,self.web,self.journal,self.receipt,self.baseline,set(),native=self.native,pending=lambda:True)
        result=audit(self.saved,self.store,self.web,self.journal,self.receipt,self.baseline,set(),native=self.native,pending=lambda:True,binding_backend=binding)
        self.assertEqual(result['result'],'READ_ONLY_RESTORED')
        self.grant['deviceId']='another-device'
        with self.assertRaises(ValueError):audit(self.saved,self.store,self.web,self.journal,self.receipt,self.baseline,set(),native=self.native,pending=lambda:True,binding_backend=binding)
    def test_changed_baseline_cannot_use_audit_binding(self):
        self.assertEqual(self.run_case()['result'],'RESTORED_FULL');binding=Backend()
        bind_audit(self.saved,self.grant,self.journal,self.receipt,self.baseline,set(),binding)
        self.grant['accessToken']='synthetic-new-access'
        record=json.loads(self.baseline.backend.data);record['plan']['baseline']['native']='f'*64
        self.baseline.backend.data=json.dumps(record).encode()
        with self.assertRaises(ValueError):audit(self.saved,self.store,self.web,self.journal,self.receipt,self.baseline,set(),native=self.native,pending=lambda:True,binding_backend=binding)
    def test_old_baseline_version_remains_auditable(self):
        self.assertEqual(self.run_case()['result'],'RESTORED_FULL')
        snapshot=project(self.probe.state);record=json.loads(self.baseline.backend.data)
        record['plan']['record']['kind']='import_cleanup_baseline'
        record['plan']['baseline']=fingerprints({'native':snapshot,'web':snapshot},version=1)
        self.baseline.backend.data=json.dumps(record).encode()
        result=audit(self.saved,self.store,self.web,self.journal,self.receipt,self.baseline,set(),native=self.native,pending=lambda:True)
        self.assertEqual(result['result'],'READ_ONLY_RESTORED')
    def test_unknown_other_field_is_captured_by_new_version(self):
        snapshot=project(self.probe.state);baseline=fingerprints({'native':snapshot,'web':snapshot})
        changed=deepcopy(snapshot);changed['groups']['7']['other']='synthetic-extra'
        difference=compare({'native':changed,'web':changed},baseline)
        for channel in ('native','web'):
            self.assertFalse(difference[channel]['group_fields']['other'])
            self.assertTrue(difference[channel]['group_fields']['updateTime'])
    def test_non_object_album_change_does_not_implicate_known_fields(self):
        snapshot=project(self.probe.state);snapshot['albums']={'present':True,'value':['synthetic-a']}
        baseline=fingerprints({'native':snapshot,'web':snapshot});changed=deepcopy(snapshot)
        changed['albums']['value']=['synthetic-b'];difference=compare({'native':changed,'web':changed},baseline)
        for channel in ('native','web'):
            self.assertFalse(difference[channel]['album_fields']['other'])
            self.assertTrue(difference[channel]['album_fields']['updateTime'])
    def test_group_and_album_field_differences_are_separately_identified(self):
        for mode,component in (('group_update','groups'),('album_update','albums')):
            with self.subTest(mode=mode):
                self.setUp();self.mode=mode;result=self.run_case();self.assertEqual(result['result'],'RESTORED_SNAPSHOT_CHANGED')
                self.assertTrue(all(result['native_original_core_matches'].values()))
                for channel in ('native','web'):
                    self.assertFalse(result['comparisons'][channel]['components'][component])
                    self.assertFalse(result['comparisons'][channel][component[:-1]+'_fields']['updateTime'])
                    self.assertTrue(result['comparisons'][channel]['components']['members'])
    def test_uncertain_cleanup_is_not_replayed(self):
        self.probe.mode='cleanup_bad_ack';result=self.run_case()
        self.assertEqual(result['result'],'UNVERIFIED');self.assertEqual(self.probe.attempts['cleanup'],1)
        self.assertEqual(self.journal.read()[0]['phase'],'cleanup_pending')
        self.assertEqual(self.run_case()['result'],'UNVERIFIED');self.assertEqual(self.probe.attempts['cleanup'],1)
    def test_unrelated_group_metadata_change_blocks_cleanup(self):
        notify=self.probe.notify
        def changed(*args):
            value=notify(*args);self.probe.state['archive'][0]['updateTime']=123;return value
        self.probe.notify=changed;result=self.run_case()
        self.assertEqual(result['result'],'UNVERIFIED');self.assertEqual(self.probe.attempts['cleanup'],0)
        self.assertEqual(self.journal.read()[0]['phase'],'imported')
    def test_uncertain_notify_does_not_clean_or_replay(self):
        self.probe.mode='notify_lost';result=self.run_case()
        self.assertEqual(result['result'],'UNVERIFIED');self.assertEqual(self.probe.attempts['notify'],1)
        self.assertEqual(self.probe.attempts['cleanup'],0);self.assertEqual(self.journal.read()[0]['phase'],'notify_pending')
        self.assertEqual(self.run_case()['result'],'UNVERIFIED');self.assertEqual(self.probe.attempts['notify'],1)
    def test_protected_target_cannot_be_removed(self):
        result=self.run_case(protected={TARGET});self.assertEqual(result['result'],'UNVERIFIED')
        self.assertEqual(self.probe.attempts['cleanup'],0);self.assertEqual(self.journal.read()[0]['phase'],'imported')
    def test_preview_has_no_writes_and_saves_no_baseline(self):
        result=self.run_case(apply=False);self.assertEqual(result['result'],'READ_ONLY_PREVIEW')
        self.assertEqual(self.probe.attempts['notify'],0);self.assertIsNone(self.baseline.read()[0])


if __name__=='__main__':unittest.main()
