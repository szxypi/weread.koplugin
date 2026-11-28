import unittest
import json
from copy import deepcopy
from functools import partial
from unittest.mock import patch

from cloud_group_fixture import Journal
from native_direct_time_trial_store import Intent
from synthetic_format_trial import TargetReceipt
from test_personal_upload_trial import FakeProbe, TARGET
from test_secure_native_session import Backend, credentials
from verify_imported_pin_fixture import audit, execute, validate_receipts
from imported_pin_audit_binding import create as create_binding
from native_imported_pin_fixture_trial import run as native_trial
from verify_synthetic_epub_upload import run as upload


class FixtureTest(unittest.TestCase):
    def setUp(self):
        self.grant=credentials();self.saved={'vid':self.grant['vid'],'cookies':{'synthetic':'cookie'}}
        self.journal=Journal(Backend());self.receipt=TargetReceipt('epub',backend=Backend(),scope='group-fixture')
        self.records={name:Intent(backend=Backend()) for name in ('baseline','pin','restore')}
        self.upload=FakeProbe();self.sent=[];self.mode='normal'
        self.point={'book':{'bookId':TARGET,'chapterUid':0,'chapterIdx':0,'chapterOffset':0,'progress':0,'updateTime':10}}
        owner=self
        class Store:
            def load(self,*_args):return deepcopy(owner.grant)
        self.native_store=Store()
        class Session:
            def load(self):return deepcopy(owner.saved)
        self.patch=patch('verify_imported_pin_fixture.SessionStore',Session);self.patch.start();self.addCleanup(self.patch.stop)
        class Web:
            def request(self,*_args):return deepcopy(owner.upload.state)
        self.web=Web()
        class Native:
            def request(self,stage,_url,body=None,credentials=None):
                assert credentials==owner.grant
                if stage=='shelf':return deepcopy(owner.upload.state)
                if stage=='progress':return deepcopy(owner.point)
                assert stage=='pin_write' and body['bookIds']==[TARGET]
                kind='pin' if body['isDel']==0 else 'restore';owner.sent.append(kind)
                row=next(row for row in owner.upload.state['books'] if row['bookId']==TARGET)
                if kind=='pin':row['isTop']=1
                else:
                    row.pop('isTop',None)
                    if owner.mode=='progress_changed':owner.point['book']['chapterOffset']=1
                if owner.mode=='lost_pin' and kind=='pin':return {}
                return {'succ':1}
        self.native=Native()
    def run_fixture(self,*,apply=True,source=True,protected='CB_another'):
        return execute(self.saved,self.native_store,self.web,self.journal,self.receipt,self.records,protected,
                       apply=apply,native=self.native,upload_probe=self.upload,
                       uploader=partial(upload,sleep=lambda _delay:None,now=lambda:1000),
                       content_reader=lambda _saved,_target:source,pending=lambda:True)
    def test_full_roundtrip_cleans_only_fixture(self):
        result=self.run_fixture();self.assertEqual(result['result'],'PASS');self.assertEqual(self.sent,['pin','restore'])
        self.assertTrue(result['original_shelves_match']);self.assertEqual(self.upload.attempts['cleanup'],1)
        self.assertEqual(self.journal.read()[0]['phase'],'restored')
        self.assertEqual(self.run_fixture()['result'],'UNVERIFIED');self.assertEqual(self.sent,['pin','restore'])
    def test_progress_difference_retains_fixture_and_identifies_field(self):
        self.mode='progress_changed';result=self.run_fixture()
        self.assertEqual(result['result'],'FIXTURE_RETAINED_UNVERIFIED');self.assertEqual(self.sent,['pin','restore'])
        self.assertEqual(self.upload.attempts['cleanup'],0);self.assertEqual(self.journal.read()[0]['phase'],'imported')
        self.assertTrue(result['component_changes']['progress_changed'])
        self.assertIn('book.chapterOffset',result['component_changes']['observed_progress_fields_changed'])
        self.assertEqual(self.records['restore'].read()[0]['phase'],'acknowledged')
    def test_unknown_pin_receipt_never_restores_or_cleans(self):
        self.mode='lost_pin';result=self.run_fixture()
        self.assertEqual(result['result'],'FIXTURE_RETAINED_UNVERIFIED');self.assertEqual(self.sent,['pin'])
        self.assertEqual(self.upload.attempts['cleanup'],0);self.assertIsNone(self.records['restore'].read()[0])
    def test_protected_target_cannot_be_written(self):
        result=self.run_fixture(protected=TARGET)
        self.assertEqual(result['result'],'UNVERIFIED');self.assertEqual(self.sent,[]);self.assertEqual(self.upload.attempts['cleanup'],0)
    def test_unverified_source_cleans_fixture_without_pin(self):
        result=self.run_fixture(source=False)
        self.assertEqual(result['result'],'FIXTURE_CLEANED_UNVERIFIED');self.assertEqual(self.sent,[])
        self.assertEqual(self.upload.attempts['cleanup'],1)
    def test_preview_has_no_writes_or_claims(self):
        result=self.run_fixture(apply=False)
        self.assertEqual(result['result'],'READ_ONLY_PREVIEW');self.assertEqual(self.sent,[])
        self.assertEqual(self.upload.attempts['notify'],0);self.assertIsNone(self.records['baseline'].read()[0])
    def test_read_only_audit_survives_same_device_renewal_only_with_prior_binding(self):
        self.assertEqual(self.run_fixture()['result'],'PASS')
        binding=Backend()
        _target,_base,pin,restore=validate_receipts(self.saved,self.grant,self.journal,self.receipt,self.records,'CB_another')
        create_binding(self.saved['vid'],self.grant,pin,restore,binding)
        before=len(self.sent)
        result=audit(self.saved,self.native_store,self.web,self.journal,self.receipt,self.records,'CB_another',
                     native=self.native,pending=lambda:True,binding=binding)
        self.assertEqual(result['result'],'READ_ONLY_RESTORED')
        self.assertTrue(all(result['native_original_core_matches'].values()))
        self.assertTrue(all(result['current_native_web_core_matches'].values()))
        self.grant['accessToken']='synthetic-renewed'
        with self.assertRaises(ValueError):
            audit(self.saved,self.native_store,self.web,self.journal,self.receipt,self.records,'CB_another',
                  native=self.native,pending=lambda:True)
        result=audit(self.saved,self.native_store,self.web,self.journal,self.receipt,self.records,'CB_another',
                     native=self.native,pending=lambda:True,binding=binding)
        self.assertEqual(result['result'],'READ_ONLY_RESTORED')
        self.assertEqual(len(self.sent),before)
        self.grant['deviceId']='different-device'
        with self.assertRaises(ValueError):
            audit(self.saved,self.native_store,self.web,self.journal,self.receipt,self.records,'CB_another',
                  native=self.native,pending=lambda:True,binding=binding)
    def test_read_only_audit_rejects_protected_fixture_and_changed_receipts(self):
        self.assertEqual(self.run_fixture()['result'],'PASS')
        with self.assertRaises(ValueError):
            validate_receipts(self.saved,self.grant,self.journal,self.receipt,self.records,TARGET)
        self.receipt.backend.data=b'{}'
        with self.assertRaises(ValueError):
            validate_receipts(self.saved,self.grant,self.journal,self.receipt,self.records,'CB_another')
    def test_audit_identifies_group_metadata_change_and_reads_old_baselines(self):
        self.assertEqual(self.run_fixture()['result'],'PASS')
        self.upload.state['archive'][0]['updateTime']=123
        result=audit(self.saved,self.native_store,self.web,self.journal,self.receipt,self.records,'CB_another',
                     native=self.native,pending=lambda:True)
        self.assertEqual(result['result'],'READ_ONLY_SNAPSHOT_CHANGED')
        self.assertTrue(all(result['native_original_core_matches'].values()))
        for channel in ('native','web'):
            self.assertFalse(result['original_components_match'][channel]['groups'])
            self.assertTrue(result['original_components_match'][channel]['members'])
        record=json.loads(self.records['baseline'].backend.data)
        record['plan']['baseline']={key:record['plan']['baseline'][key] for key in ('native','web')}
        self.records['baseline'].backend.data=json.dumps(record).encode()
        result=audit(self.saved,self.native_store,self.web,self.journal,self.receipt,self.records,'CB_another',
                     native=self.native,pending=lambda:True)
        self.assertEqual(result['result'],'READ_ONLY_SNAPSHOT_CHANGED')
        self.assertNotIn('original_components_match',result)
    def test_native_fixture_cleanup_only_after_both_independent_readbacks(self):
        for mode in ('normal','lost_first','dry_failure'):
            with self.subTest(mode=mode):
                self.setUp();sent=[]
                def execute_trial(grant,target,before,observe,current,records,mark_armed):
                    def child(_payload,_command,*,armed,on_step):
                        if not armed:
                            if mode=='dry_failure':raise ValueError('dry failed')
                            return {'result':'PASS'},0
                        sent.append('pin');self.upload.state['books'][-1]['isTop']=1
                        if mode=='lost_first':raise ValueError('lost receipt')
                        on_step(1);sent.append('restore');self.upload.state['books'][-1].pop('isTop');on_step(2)
                        return {'result':'PASS'},2
                    return native_trial(grant,target,before,observe,current,records,{'bookId':target,'title':'Synthetic'},
                                        ['synthetic'],mark_armed,child=child,sleep=lambda _delay:None)
                result=execute(self.saved,self.native_store,self.web,self.journal,self.receipt,self.records,'CB_another',
                    apply=True,native=self.native,upload_probe=self.upload,uploader=partial(upload,sleep=lambda _d:None,now=lambda:1000),
                    content_reader=lambda _saved,_target:True,pending=lambda:True,trial_executor=execute_trial)
                if mode=='normal':
                    self.assertEqual(result['result'],'PASS');self.assertEqual(sent,['pin','restore'])
                    self.assertEqual(result['pin_posts_attempted'],2);self.assertEqual(self.upload.attempts['cleanup'],1)
                elif mode=='lost_first':
                    self.assertEqual(result['result'],'FIXTURE_RETAINED_UNVERIFIED');self.assertEqual(sent,['pin'])
                    self.assertIsNone(result['pin_posts_attempted']);self.assertEqual(self.upload.attempts['cleanup'],0)
                else:
                    self.assertEqual(result['result'],'FIXTURE_CLEANED_UNVERIFIED');self.assertEqual(sent,[])
                    self.assertEqual(self.upload.attempts['cleanup'],1)


if __name__=='__main__':unittest.main()
