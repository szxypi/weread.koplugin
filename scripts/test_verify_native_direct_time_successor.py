"""One-shot successor must not replay the previous time interval."""
from copy import deepcopy
import unittest

from native_direct_time_trial_store import Intent
from test_cb_fixture_position_transport import MemoryBackend
from test_native_direct_time_trial_contract import fixture
from verify_native_direct_time_successor import PriorGuard
from verify_native_direct_time_automatic import PriorGuards


class SuccessorTests(unittest.TestCase):
    def setUp(self):
        self.now,self.grant,_,self.selection,_,baseline,event=fixture()
        self.backend=MemoryBackend();self.store=Intent(backend=self.backend)
        self.plan=dict(selection=deepcopy(self.selection),record=deepcopy(event['record']),
            body=deepcopy(event['body']),baseline=deepcopy(baseline))
        self.receipt=self.store.claim(self.plan,now=self.now)

    def ack(self):
        self.receipt=self.store.advance(self.receipt,'acknowledged')
        return PriorGuard(self.store)

    def test_old_claim_without_ack_is_not_reusable(self):
        with self.assertRaises(ValueError):PriorGuard(self.store)

    def test_distinct_later_interval_only(self):
        guard=self.ack();self.assertTrue(guard.check(self.grant))
        with self.assertRaisesRegex(ValueError,'overlap'):guard.check(self.grant,self.selection)
        later=deepcopy(self.selection);later['protocol_rows'][0]['start_time']+=6
        self.assertTrue(guard.check(self.grant,later,self.plan['record']))
        later['protocol_rows'].append(dict(later['protocol_rows'][0],start_time=self.now-7))
        with self.assertRaisesRegex(ValueError,'overlap'):guard.check(self.grant,later)
        with self.assertRaises(ValueError):guard.check(dict(self.grant,vid='900001'))
        with self.assertRaises(ValueError):guard.check(self.grant,None,dict(self.plan['record'],account='wrong'))

    def test_prior_cannot_change_during_new_attempt(self):
        guard=self.ack();self.store.advance(self.receipt,'verified')
        with self.assertRaises(ValueError):guard.check(self.grant)

    def test_corrupted_prior_body_and_rows_are_rejected(self):
        self.ack()
        for change in ('body','duration','seconds'):
            backend=MemoryBackend();store=Intent(backend=backend);plan=deepcopy(self.plan)
            if change=='body':plan['body']['books'][0]['readingTime']+=1
            elif change=='duration':plan['selection']['protocol_rows'][0]['duration']=0
            else:plan['selection']['seconds']+=1
            receipt=store.claim(plan,now=self.now);store.advance(receipt,'acknowledged')
            with self.subTest(change=change),self.assertRaises(ValueError):PriorGuard(store)

    def test_automatic_checks_both_immutable_predecessors(self):
        self.ack();other=Intent(backend=MemoryBackend())
        receipt=other.claim(deepcopy(self.plan),now=self.now);other.advance(receipt,'acknowledged')
        guards=PriorGuards([self.store,other]);self.assertTrue(guards.unchanged())
        with self.assertRaises(ValueError):guards.check(self.grant,self.selection)
        later=deepcopy(self.selection);later['protocol_rows'][0]['start_time']+=6
        self.assertTrue(guards.check(self.grant,later));self.assertTrue(guards.unchanged())
        value,receipt=other.read();other.advance(receipt,'verified')
        self.assertEqual(value['phase'],'acknowledged');self.assertFalse(guards.unchanged())
        with self.assertRaises(ValueError):guards.check(self.grant,later)


if __name__=='__main__':unittest.main()
