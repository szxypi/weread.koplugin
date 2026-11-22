import unittest

from ordinary_reconnect_coordinator import Coordinator
from secure_ordinary_reconnect_trial import OrdinaryReconnectStore
from test_ordinary_reconnect_body_guard import body
from test_secure_native_session import Backend
from test_secure_ordinary_reconnect_trial import plan


class CoordinatorTests(unittest.TestCase):
    def setUp(self):
        self.plan = plan(); self.context = dict(psvts='synthetic-ps', token='synthetic-token'); self.pc = 'synthetic-pc'
        self.store = OrdinaryReconnectStore(Backend()); self.store.reserve(self.plan)
        self.events = []
    def make(self, armed=True):
        def before(stage, selected): self.events.append(('before', stage)); return selected == self.plan
        def after(stage, selected): self.events.append(('after', stage)); return selected == self.plan
        return Coordinator(self.store, self.plan, self.context, self.pc, before, after, armed=armed)
    def wire(self, stage): return body(self.plan, self.context, self.pc, stage)

    def test_complete_sequence_and_independent_checks(self):
        gate = self.make()
        for stage in ('enter', 'position', 'restore'):
            self.assertTrue(gate.claim(stage, self.wire(stage)))
            gate.ack(stage, 200, {'succ': 1}); gate.verify(stage)
        self.assertEqual(self.store.read()[0]['phase'], 'retired')
        self.assertEqual(self.events, [(which, stage) for stage in ('enter', 'position', 'restore') for which in ('before', 'after')])
        with self.assertRaises(ValueError): gate.claim('enter', self.wire('enter'))

    def test_dry_run_cannot_send_and_leaves_record_unclaimed(self):
        gate = self.make(False)
        self.assertFalse(gate.claim('enter', self.wire('enter')))
        self.assertEqual(self.store.read()[0]['phase'], 'prepared')
        with self.assertRaises(ValueError): gate.ack('enter', 200, {'succ': 1})

    def test_ambiguous_receipt_or_failed_readback_stops_at_current_stage(self):
        gate = self.make(); gate.claim('enter', self.wire('enter'))
        with self.assertRaises(ValueError): gate.ack('enter', 200, {})
        self.assertEqual(self.store.read()[0]['phase'], 'enter_pending')
        with self.assertRaises(ValueError): gate.claim('enter', self.wire('enter'))
        with self.assertRaises(ValueError): self.make()
        with self.assertRaises(ValueError): gate.ack('enter', 200, {'succ': 1})

        self.store = OrdinaryReconnectStore(Backend()); self.store.reserve(self.plan)
        gate = self.make(); gate.claim('enter', self.wire('enter'))
        gate.ack('enter', 200, {'succ': 1}); gate.after = lambda *_: False
        with self.assertRaises(ValueError): gate.verify('enter')
        self.assertEqual(self.store.read()[0]['phase'], 'enter_acknowledged')
        with self.assertRaises(ValueError): gate.claim('position', self.wire('position'))

    def test_before_failure_and_out_of_order_cannot_consume_slots(self):
        gate = self.make(); gate.before = lambda *_: False
        with self.assertRaises(ValueError): gate.claim('enter', self.wire('enter'))
        with self.assertRaises(ValueError): gate.claim('restore', self.wire('restore'))
        self.assertEqual(self.store.read()[0]['phase'], 'prepared')

    def test_caller_mutation_cannot_change_bound_plan_or_context(self):
        gate = self.make()
        original = self.wire('enter')
        self.plan['target']['chapter_offset'] += 1
        self.context['psvts'] = 'changed'
        gate.before = lambda stage, selected: selected['target']['chapter_offset'] == 300
        self.assertTrue(gate.claim('enter', original))
        self.assertEqual(self.store.read()[0]['phase'], 'enter_pending')


if __name__ == '__main__': unittest.main()
