import copy
import unittest

import ordinary_reconnect_body_guard as guard
from test_secure_ordinary_reconnect_trial import plan
from verify_position_roundtrip import payload, weread_sign, sorted_query
from fetch_weread_epub import weread_e


def body(trial, context, pclts, stage):
    point = trial['baseline' if stage == 'restore' else 'target']
    wire = dict(book_id=point['book_id'], baseline=point, target=None, context=context, pclts=pclts)
    return payload(wire, 'write_enter' if stage == 'enter' else 'write_restore')


class BodyGuardTests(unittest.TestCase):
    def setUp(self):
        self.plan = plan(); self.context = dict(psvts='synthetic-ps', token='synthetic-token'); self.pc = 'synthetic-pc'

    def test_each_stage_is_bound_to_the_right_position(self):
        for stage in ('enter', 'position', 'restore'):
            with self.subTest(stage=stage):
                self.assertTrue(guard.validate_body(self.plan, self.context, self.pc, stage,
                                                    body(self.plan, self.context, self.pc, stage)))
        target = body(self.plan, self.context, self.pc, 'position')
        with self.assertRaises(ValueError): guard.validate_body(self.plan, self.context, self.pc, 'restore', target)

    def test_signed_changes_and_foreign_context_are_rejected(self):
        original = body(self.plan, self.context, self.pc, 'position')
        for key, value in [('co', 100), ('sm', 'different'), ('pr', 50), ('rt', 1), ('b', 'foreign'),
                           ('ps', 'foreign'), ('pc', 'foreign'), ('sg', 'incorrect')]:
            candidate = copy.deepcopy(original); candidate[key] = value
            candidate['s'] = weread_sign(sorted_query({k: v for k, v in candidate.items() if k != 's'}))
            with self.subTest(key=key), self.assertRaises(ValueError):
                guard.validate_body(self.plan, self.context, self.pc, 'position', candidate)
        for stage in ('enter', 'position', 'restore'):
            candidate = body(self.plan, self.context, self.pc, stage)
            with self.assertRaises(ValueError): guard.validate_body(self.plan, self.context, 'other-pc', stage, candidate)

    def test_wrong_shape_and_stale_request_rejected(self):
        candidate = body(self.plan, self.context, self.pc, 'position')
        with self.assertRaises(ValueError): guard.validate_body(self.plan, {}, self.pc, 'position', candidate)
        with self.assertRaises(ValueError): guard.validate_body(self.plan, self.context, self.pc, 'other', candidate)
        with self.assertRaises(ValueError): guard.validate_body(self.plan, self.context, self.pc, 'position', candidate,
                                                               observed_at=candidate['ct'] + 31)
        with self.assertRaises(ValueError): guard.validate_body(self.plan, self.context, self.pc, 'enter', candidate)

    def test_missing_context_counter_can_bind_only_a_fresh_encoded_counter(self):
        candidate = body(self.plan, self.context, self.pc, 'enter')
        candidate['pc'] = weread_e(candidate['ct'])
        candidate['s'] = weread_sign(sorted_query({k: v for k, v in candidate.items() if k != 's'}))
        self.assertTrue(guard.validate_body(self.plan, self.context, None, 'enter', candidate))
        self.assertTrue(guard.validate_body(self.plan, dict(self.context, pclts=0), None, 'enter', candidate))
        stale = dict(candidate, pc=weread_e(candidate['ct']-31))
        stale['s'] = weread_sign(sorted_query({k: v for k, v in stale.items() if k != 's'}))
        with self.assertRaises(ValueError): guard.validate_body(self.plan, self.context, None, 'enter', stale)
        with self.assertRaises(ValueError): guard.validate_body(self.plan, dict(self.context, pclts='bound'), None, 'enter', candidate)
        with self.assertRaises(ValueError): guard.validate_body(self.plan, dict(self.context, pclts=False), None, 'enter', candidate)
        with self.assertRaises(ValueError): guard.validate_body(self.plan, self.context, None, 'position', candidate)


if __name__ == '__main__': unittest.main()
