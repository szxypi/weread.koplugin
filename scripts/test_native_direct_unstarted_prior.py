"""Earlier experiment receipts cannot be reused or silently changed."""
from copy import deepcopy
import hashlib
import unittest
from native_direct_time_trial_store import Intent
from native_direct_unstarted_prior import PriorSamples
from native_time_capture_evidence import account_key
from test_secure_native_session import Backend,credentials


def verified(store,plan,stamp):
    raw=store.claim(plan,now=stamp);raw=store.advance(raw,'acknowledged');return store.advance(raw,'verified')


class PriorTests(unittest.TestCase):
    def setUp(self):
        self.grant=credentials();owner=account_key(self.grant['vid'])
        self.stores=[Intent(backend=Backend()) for _ in range(4)]
        source1=dict(book_id='41',version=1,source_sha256='a'*64)
        old=dict(selection=dict(duration=2,start_time=100),record=dict(owner=owner,source=source1),
            body=dict(books=[dict(bookId='41',readingTime=2)]),baseline={})
        first=verified(self.stores[0],old,103);first_state=self.stores[0].read()[0]
        position=dict(selection=dict(target=dict(book_id='41')),record=dict(prior_attempt=first_state['attempt'],
            prior_receipt_sha256=hashlib.sha256(first).hexdigest(),version=1),body={},baseline={})
        verified(self.stores[1],position,110)
        source2=dict(book_id='42',version=1,source_sha256='b'*64)
        second=dict(selection=dict(duration=2,start_time=120),record=dict(owner=owner,source=source2),
            body=dict(books=[dict(bookId='42',readingTime=2)]),baseline={})
        verified(self.stores[2],second,123)
        ui_position=dict(selection=dict(book_id='42',source_sha256='b'*64),record=dict(account=owner),body={},baseline={})
        verified(self.stores[3],ui_position,130)
        self.guard=PriorSamples(*self.stores)
    def test_distinct_sample_and_later_interval(self):
        self.assertTrue(self.guard.check(self.grant,'43',dict(protocol_rows=[dict(start_time=131,duration=6)])))
    def test_previous_book_interval_or_other_account_is_rejected(self):
        for book in ('41','42'):
            with self.assertRaises(ValueError):self.guard.check(self.grant,book)
        with self.assertRaises(ValueError):self.guard.check(self.grant,'43',dict(protocol_rows=[dict(start_time=129)]))
        grant=deepcopy(self.grant);grant['vid']='900001'
        with self.assertRaises(ValueError):self.guard.check(grant,'43')
    def test_changed_or_pending_prior_is_rejected(self):
        self.stores[3].backend.data=b'corrupt'
        with self.assertRaises(Exception):self.guard.check(self.grant,'43')
        with self.assertRaises(ValueError):PriorSamples(*self.stores[:3],Intent(backend=Backend()))


if __name__=='__main__':unittest.main()
