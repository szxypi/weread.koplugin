"""Offline tests for immutable prior-account and distinct-book checks."""
from copy import deepcopy
from contextlib import ExitStack
import hashlib
import unittest
from unittest.mock import patch
from native_direct_time_trial_store import Intent
from native_time_capture_evidence import account_key
from ordinary_unstarted_ui_prior import PreviousSamples,OrdinaryUnstartedUiTimeStore,OrdinaryUnstartedUiPositionStore,inspect_book
from test_secure_native_session import Backend,credentials


class PriorTests(unittest.TestCase):
    def setUp(self):
        self.grant=credentials();self.first=Intent(backend=Backend());self.second=Intent(backend=Backend())
        old=dict(selection=dict(duration=2,start_time=100),record=dict(owner=account_key(self.grant['vid']),
            source=dict(book_id='41',version=1)),body=dict(books=[dict(bookId='41',readingTime=2)]),baseline={})
        raw=self.first.claim(old,now=103);raw=self.first.advance(raw,'acknowledged');raw=self.first.advance(raw,'verified')
        prior=self.first.read()[0]
        new=dict(selection=dict(target=dict(book_id='41')),record=dict(prior_attempt=prior['attempt'],
            prior_receipt_sha256=hashlib.sha256(raw).hexdigest(),version=1),body={},baseline={})
        raw=self.second.claim(new,now=110);raw=self.second.advance(raw,'acknowledged');self.second.advance(raw,'verified')
        self.guard=PreviousSamples(self.first,self.second);self.selected=dict(book_id='42')
    def test_distinct_book_and_later_interval(self):
        self.assertTrue(self.guard.check(self.grant,self.selected,dict(protocol_rows=[dict(start_time=111,duration=2)])))
    def test_same_book_or_old_interval_is_rejected(self):
        for selected,interval in ((dict(book_id='41'),None),(self.selected,dict(protocol_rows=[dict(start_time=109,duration=2)]))):
            with self.assertRaises(ValueError):self.guard.check(self.grant,selected,interval)
    def test_account_or_prior_record_change_is_rejected(self):
        grant=deepcopy(self.grant);grant['vid']='900001'
        with self.assertRaises(ValueError):self.guard.check(grant,self.selected)
        self.first.backend.data=b'changed'
        with self.assertRaises(Exception):self.guard.check(self.grant,self.selected)
    def test_unverified_prior_is_rejected(self):
        with self.assertRaises(ValueError):PreviousSamples(Intent(backend=Backend()),self.second)
    def test_reordered_shelf_still_binds_the_selected_book(self):
        class Probe:
            def request(self,*_args,**_kwargs):return {'books':[{'bookId':'42'},{'bookId':'41'}]}
            def inspect(self,_grant,offset):
                self_outer.assertEqual(offset,1)
                return dict(book_id='41'),{},{}
        self_outer=self
        with patch('ordinary_unstarted_ui_prior.ChapterProbe',Probe):
            self.assertEqual(inspect_book(self.grant,'41')[0]['book_id'],'41')
            with self.assertRaises(ValueError):inspect_book(self.grant,'99')
    def test_scopes_are_separate_and_pending_globally_blocks_other_trials(self):
        self.assertNotEqual(OrdinaryUnstartedUiTimeStore.service,OrdinaryUnstartedUiPositionStore.service)
        import verify_native_thought_trial as shared
        with ExitStack() as stack:
            factories={}
            for name in dir(shared):
                if name.endswith('Store'):
                    factory=stack.enter_context(patch.object(shared,name));factories[name]=factory
                    factory.return_value.pending.return_value=False;factory.return_value.read.return_value=(None,None)
            self.assertFalse(shared.other_pending())
            time=factories['OrdinaryUnstartedUiTimeStore'].return_value
            position=factories['OrdinaryUnstartedUiPositionStore'].return_value
            time.pending.return_value=True
            self.assertTrue(shared.other_pending(exclude_ordinary_ui_position=True))
            self.assertFalse(shared.other_pending(exclude_ordinary_ui_time=True))
            position.pending.return_value=True
            self.assertTrue(shared.other_pending(exclude_ordinary_ui_time=True))
            self.assertFalse(shared.other_pending(exclude_ordinary_ui_time=True,exclude_ordinary_ui_position=True))
            direct=factories['NativeDirectUnstartedTimeStore'].return_value;direct.pending.return_value=True
            self.assertTrue(shared.other_pending(exclude_ordinary_ui_time=True,exclude_ordinary_ui_position=True))
            self.assertFalse(shared.other_pending(exclude_ordinary_ui_time=True,exclude_ordinary_ui_position=True,
                exclude_direct_unstarted_time=True))


if __name__=='__main__':unittest.main()
