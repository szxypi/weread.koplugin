import unittest
from test_pin_trial_contract import Fixture
from verify_pin_preflight import fingerprint
from inspect_pin_cleanup import assess,resolve_inspection


class InspectionTests(unittest.TestCase):
    def setup_trial(self):
        f=Fixture(False);_,raw=f.store.reserve(f.plan,fingerprint(f.progress),'c'*64)
        _,raw=f.store.advance(raw,'add_pending');f.store.advance(raw,'add_acknowledged');f.present=True
        return f

    def test_restored_shelf_and_changed_progress_are_distinct(self):
        f=self.setup_trial();state,raw=f.store.read();f.store.cleanup(raw);state,_=f.store.read();f.present=False;f.bad='progress'
        result=assess(state,f.read)
        self.assertTrue(result['original_shelf_restored']);self.assertFalse(result['progress_matches_before_add'])
        self.assertTrue(result['current_progress_stable']);self.assertEqual(f.writes,[])
    def test_unrestored_shelf_fails(self):
        f=self.setup_trial();state,raw=f.store.read();f.store.cleanup(raw);state,_=f.store.read()
        with self.assertRaises(Exception):assess(state,f.read)
    def test_wrong_phase_fails(self):
        f=self.setup_trial();state,_=f.store.read()
        with self.assertRaises(ValueError):assess(state,f.read)

    def test_timestamp_proof_resolves_with_distinct_auditable_state(self):
        f=self.setup_trial();_,raw=f.store.read();_,raw=f.store.cleanup(raw);state,_=f.store.read();f.present=False;f.bad='progress'
        result=assess(state,f.read,proof=lambda position,digest:True)
        result_state,_=resolve_inspection(f.store,raw,result)
        self.assertTrue(result['only_book_update_time_changed_proven'])
        self.assertEqual(result_state['phase'],'add_cleanup_timestamp_changed')
        self.assertFalse(f.store.pending())
        with self.assertRaises(Exception):resolve_inspection(f.store,raw,result)

    def test_unproven_change_or_invalid_evidence_cannot_resolve(self):
        f=self.setup_trial();_,raw=f.store.read();_,raw=f.store.cleanup(raw);state,_=f.store.read();f.present=False;f.bad='progress'
        result=assess(state,f.read,proof=lambda position,digest:False)
        with self.assertRaises(ValueError):resolve_inspection(f.store,raw,result)
        result['only_book_update_time_changed_proven']=True;result['current_progress_stable']=False
        with self.assertRaises(ValueError):resolve_inspection(f.store,raw,result)
        self.assertTrue(f.store.pending())


if __name__=='__main__':unittest.main()
