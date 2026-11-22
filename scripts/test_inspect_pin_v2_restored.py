import unittest
from inspect_pin_v2_restored import assess
from pin_trial_contract import run
from test_pin_trial_contract import Fixture
from verify_pin_preflight import reading_fingerprint


class RestoredReadbackTests(unittest.TestCase):
    def completed(self):
        f=Fixture(False);f.progress={'book':{'updateTime':100,'chapterOffset':0},'timestamp':1}
        run(f.plan,reading_fingerprint(f.progress),'c'*64,f.store,f.current,f.read,f.write,progress_digest=reading_fingerprint)
        return f
    def test_exact_reading_fields_and_three_shelves(self):
        f=self.completed();state,_=f.store.read();f.progress['book']['updateTime']=101
        result=assess(state,f.read)
        self.assertTrue(result['original_shelf_restored']);self.assertTrue(result['reading_fields_unchanged'])
        self.assertFalse(result['book_update_time_compared']);self.assertEqual(f.writes,['add','pin','unpin','remove'])
    def test_changed_position_or_shelf_stops(self):
        for change in ('position','shelf'):
            f=self.completed();state,_=f.store.read()
            if change=='position':f.progress['book']['chapterOffset']=1
            else:f.present=True
            with self.subTest(change=change),self.assertRaises(ValueError):assess(state,f.read)
    def test_pending_record_not_a_restoration(self):
        f=self.completed();state,_=f.store.read();state['phase']='pin_pending'
        with self.assertRaises(ValueError):assess(state,f.read)


if __name__=='__main__':unittest.main()
