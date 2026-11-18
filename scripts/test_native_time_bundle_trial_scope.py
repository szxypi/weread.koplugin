"""Fresh capture comparison is bound to the same consumed trials and fixture."""
from copy import deepcopy
import unittest
from unittest.mock import Mock,patch

from annotation_experiment_model import canonical
from native_time_bundle_trial_scope import LiveTrialReader,from_journals,validate
from test_native_time_bundle_evidence import evidence_fixture,synthetic_trial


class TrialScopeTests(unittest.TestCase):
    def test_same_scope_is_deterministic_and_contains_no_journal_contents(self):
        bundle,*_=evidence_fixture();values=synthetic_trial(bundle)
        scope=from_journals(bundle,*values)
        self.assertEqual(validate(bundle,scope),scope)
        self.assertEqual(from_journals(bundle,*values),scope)
        self.assertEqual(set(scope),{'target','owner_sha256','upload_sha256','group_sha256','old_sha256'})

    def test_mismatched_or_changed_trial_records_are_rejected(self):
        for mode in ('upload_raw','group_raw','old_raw','target','owner','upload_attempt','plan','phase','dispatched','old_phase'):
            bundle,*_=evidence_fixture();values=list(deepcopy(synthetic_trial(bundle)))
            if mode=='upload_raw':values[1]=b'{}'
            elif mode=='group_raw':values[3]=b'{}'
            elif mode=='old_raw':values[5]=b'{}'
            elif mode=='target':values[2]['target']='CB_Other';values[3]=canonical(values[2])
            elif mode=='owner':values[4]['owner']='999';values[5]=canonical(values[4])
            elif mode=='upload_attempt':values[2]['upload_attempt']='b'*32;values[3]=canonical(values[2])
            elif mode=='plan':values[2]['upload_plan_hash']='a'*64;values[3]=canonical(values[2])
            elif mode=='phase':values[2]['phase']='created';values[3]=canonical(values[2])
            elif mode=='dispatched':values[2]['dispatched']=False;values[3]=canonical(values[2])
            else:values[4]['phase']='restored';values[5]=canonical(values[4])
            with self.subTest(mode=mode),self.assertRaises(ValueError):from_journals(bundle,*values)

    def test_scope_is_bound_to_account_and_contains_only_expected_fields(self):
        bundle,*_=evidence_fixture();scope=from_journals(bundle,*synthetic_trial(bundle))
        for key,value in (('target','other'),('owner_sha256','a'*64),('old_sha256','bad'),('extra',True)):
            changed=dict(scope,**{key:value})
            with self.subTest(key=key),self.assertRaises(ValueError):validate(bundle,changed)

    def test_live_reader_rechecks_all_journals_and_current_account(self):
        bundle,*_=evidence_fixture();upload,upload_raw,group,group_raw,old,old_raw=synthetic_trial(bundle)
        for mode in ('match','current','upload','group','old'):
            with self.subTest(mode=mode):
                uploads,groups,olds,receipt=Mock(),Mock(),Mock(),Mock();current=Mock(return_value=True)
                groups.read.return_value=(group,group_raw);olds.read.return_value=(old,old_raw)
                if mode=='current':current.side_effect=[True,False]
                if mode=='group':groups.read.side_effect=[(group,group_raw),(group,b'changed')]
                if mode=='old':olds.read.side_effect=[(old,old_raw),(old,b'changed')]
                values=[(upload,upload_raw),(upload,upload_raw)]
                if mode=='upload':values[-1]=(upload,None)
                reader=LiveTrialReader(bundle,current,upload=uploads,group=groups,old=olds,receipt=receipt)
                with patch('cloud_group_fixture.binding',side_effect=values):
                    if mode=='match':self.assertEqual(reader(),from_journals(bundle,*synthetic_trial(bundle)))
                    else:
                        with self.assertRaises(ValueError):reader()


if __name__=='__main__':unittest.main()
