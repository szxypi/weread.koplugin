import copy
import unittest

from secure_pin_trial import PinTrialStore
from test_secure_pin_trial import Backend,plans
from verify_pin_preflight import fingerprint,reading_fingerprint
from pin_trial_contract import run


class Fixture:
    def __init__(self,visible=True):
        self.present=False;self.pinned=False;self.visible=visible;self.writes=[];self.bad=None;self.reads=0
        self.store=PinTrialStore(Backend());self.plan=plans();self.progress={'position':1}
    def current(self):
        if self.bad=='account':raise ValueError('changed')
    def read(self):
        self.reads+=1
        shelf={'books':[{'bookId':'41','title':'Synthetic book','secret':0,'finishReading':0}],'archive':[]}
        if self.present:
            row={'bookId':'42','title':'Target','secret':0,'finishReading':0}
            if self.visible:row['isTop']=int(self.pinned)
            shelf['books'].append(row)
        if self.bad=='unrelated' and self.present:shelf['books'][0]['finishReading']=1
        progress={'position':2} if self.bad=='progress' else self.progress
        return {k:copy.deepcopy(shelf) for k in ('native','web','gateway')},progress
    def write(self,operation):
        self.writes.append(operation)
        if self.bad=='timeout':raise TimeoutError()
        if self.bad=='receipt':return {}
        if operation=='add':self.present=True
        if operation=='pin':self.pinned=True
        if operation=='unpin':self.pinned=False
        if operation=='remove':self.present=False
        return {'succ':1}
    def run(self):return run(self.plan,fingerprint(self.progress),'c'*64,self.store,self.current,self.read,self.write)


class ContractTests(unittest.TestCase):
    def test_observed_roundtrip(self):
        f=Fixture();result=f.run()
        self.assertEqual(f.writes,['add','pin','unpin','remove'])
        self.assertEqual(result['result'],'PIN_OBSERVED_RESTORED')
        self.assertEqual(f.store.read()[0]['phase'],'restored')
        with self.assertRaises(ValueError):f.run()
        self.assertEqual(len(f.writes),4)
    def test_missing_pin_is_not_claimed_verified(self):
        f=Fixture(False);result=f.run()
        self.assertEqual(result['result'],'RESTORED_PIN_UNOBSERVABLE')
        self.assertEqual(result['observable_channels'],[])
    def test_visible_but_unchanged_pin_is_not_called_unobservable(self):
        f=Fixture();write=f.write
        def no_pin_effect(operation):
            result=write(operation)
            if operation=='pin':f.pinned=False
            return result
        f.write=no_pin_effect
        self.assertEqual(f.run()['result'],'RESTORED_PIN_NOT_CONFIRMED')
    def test_timeout_and_ambiguous_receipt_never_retry(self):
        for failure in ('timeout','receipt'):
            f=Fixture();f.bad=failure
            with self.subTest(failure=failure),self.assertRaises(Exception):f.run()
            self.assertEqual(f.writes,['add']);self.assertEqual(f.store.read()[0]['phase'],'add_pending')
            with self.assertRaises(ValueError):f.run()
    def test_unrelated_change_stops_before_next_write(self):
        f=Fixture();old=f.write
        def write(op):
            result=old(op)
            if op=='add':f.bad='unrelated'
            return result
        f.write=write
        with self.assertRaises(ValueError):f.run()
        self.assertEqual(f.writes,['add']);self.assertEqual(f.store.read()[0]['phase'],'add_acknowledged')
    def test_account_and_progress_changed_prevent_writes(self):
        for failure in ('account','progress'):
            f=Fixture();f.bad=failure
            with self.subTest(failure=failure),self.assertRaises(ValueError):f.run()
            self.assertEqual(f.writes,[]);self.assertIsNone(f.store.read()[0])
    def test_already_pinned_on_add_stops(self):
        f=Fixture();f.pinned=True
        with self.assertRaises(ValueError):f.run()
        self.assertEqual(f.writes,['add']);self.assertEqual(f.store.read()[0]['phase'],'add_acknowledged')

    def test_v2_allows_only_update_time_drift(self):
        f=Fixture(False);f.progress={'book':{'updateTime':100,'chapterOffset':0},'timestamp':1}
        initial=reading_fingerprint(f.progress);write=f.write
        def changed_time(op):
            result=write(op);f.progress['book']['updateTime']+=1;return result
        result=run(f.plan,initial,'c'*64,f.store,f.current,f.read,changed_time,progress_digest=reading_fingerprint)
        self.assertEqual(f.writes,['add','pin','unpin','remove'])
        self.assertTrue(result['progress_projection_verified'])
        self.assertNotIn('original_members_flags_groups_and_progress_verified',result)
    def test_v2_changed_reading_position_stops_after_add(self):
        f=Fixture(False);f.progress={'book':{'updateTime':100,'chapterOffset':0},'timestamp':1}
        initial=reading_fingerprint(f.progress);write=f.write
        def changed_position(op):
            result=write(op);f.progress['book']['chapterOffset']=1;return result
        with self.assertRaisesRegex(ValueError,'pin/observation'):
            run(f.plan,initial,'c'*64,f.store,f.current,f.read,changed_position,progress_digest=reading_fingerprint)
        self.assertEqual(f.writes,['add']);self.assertEqual(f.store.read()[0]['phase'],'add_acknowledged')


if __name__=='__main__':unittest.main()
