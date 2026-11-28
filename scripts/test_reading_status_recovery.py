"""Synthetic recovery tests, with no real Keychain or network access."""
from copy import deepcopy
import unittest
from unittest.mock import patch

from cloud_group_fixture import binding
from native_direct_time_trial_store import Intent
from personal_upload_trial import hash_value
from reading_status_fixture_trial import request
from reading_status_recovery import reconstruct, run
from resolve_reading_status_fixture import RecoveryProbe
from test_reading_status_fixture import fixture
from test_secure_native_session import Backend, credentials


def baseline():
    return {'native': {'finishReading': 0}, 'web': {'finishReading': 0},
            'progress': {'flag': 0, 'position': {'chapterUid': 0}, 'counters': {'readingTime': 0},
                         'observed': {'isStartReading': 0, 'startReadingTime': 0}}}


def setup():
    journal, receipt = fixture()
    state, _ = binding(journal, receipt.backend)
    mark, restore = Intent(backend=Backend()), Intent(backend=Backend())
    expected = {'owner': state['plan']['owner'], 'target': state['target'], 'upload_attempt': state['attempt'],
                'upload_plan_hash': hash_value(state['plan']), 'grant_hash': state['plan']['grant_sha256']}
    plan = {'selection': expected, 'record': {'kind': 'mark'}, 'body': request(state['target'], False),
            'baseline': {'snapshot_hash': hash_value(baseline())}}
    mark.claim(plan)
    return journal, receipt, state, mark, restore


class RecoveryTests(unittest.TestCase):
    def test_reconstruction_requires_saved_exact_baseline(self):
        after = baseline()
        after['progress']['flag'] = 1
        after['progress']['observed'].update(isStartReading=1, startReadingTime=999)
        self.assertEqual(reconstruct(after, hash_value(baseline())), baseline())
        after['progress']['counters']['readingTime'] = 5
        with self.assertRaises(ValueError):
            reconstruct(after, hash_value(baseline()))

    def exercise(self, mode):
        _, _, state, mark, restore = setup()
        values = {'snapshot': baseline(), 'sent': 0}
        values['snapshot']['progress']['flag'] = 1
        values['snapshot']['progress']['observed'].update(isStartReading=1, startReadingTime=999)
        def observe(_state):
            return deepcopy(values['snapshot'])
        def send(_state, plan):
            restore.claim(plan)
            values['sent'] += 1
            if mode != 'no_effect':
                values['snapshot'] = baseline()
            if mode == 'lost':
                raise TimeoutError()
            return {} if mode == 'unknown_ack' else {'succ': 1}
        result = run(mark, restore, lambda: state, lambda: True, lambda: True, observe, send)
        return result, values, state, mark, restore, observe, send

    def test_readback_resolves_unknown_receipt_without_replay(self):
        for mode in ('lost', 'unknown_ack'):
            with self.subTest(mode=mode):
                result, values, state, mark, restore, observe, send = self.exercise(mode)
                self.assertEqual(result['result'], 'RESTORED_ACK_UNKNOWN')
                self.assertTrue(result['flag_restored'] and result['exact_baseline_restored'])
                self.assertEqual(values['sent'], 1)
                again = run(mark, restore, lambda: state, lambda: True, lambda: True, observe, send)
                self.assertEqual(again['restore_posts'], 0)
                self.assertEqual(values['sent'], 1)

    def test_no_effect_never_retries(self):
        result, values, _, _, _, _, _ = self.exercise('no_effect')
        self.assertEqual(result['result'], 'UNVERIFIED')
        self.assertFalse(result['flag_restored'])
        self.assertEqual(values['sent'], 1)

    def test_recovery_transport_claims_before_network_and_rejects_retry(self):
        journal, receipt, state, mark, restore = setup()
        grant = credentials()
        probe = RecoveryProbe(grant, lambda: True, lambda: True, journal, receipt, mark, restore)
        mark_value, _ = mark.read()
        plan = {'selection': mark_value['plan']['selection'], 'record': {'kind': 'restore'},
                'body': request(state['target'], True), 'baseline': {'snapshot_hash': 'a' * 64}}
        with patch('verify_eink_login.NativeProbe.request', side_effect=TimeoutError) as dispatch:
            with self.assertRaises(TimeoutError):
                probe.send(state, plan)
            self.assertEqual(restore.read()[0]['phase'], 'claimed')
            with self.assertRaises(ValueError):
                probe.send(state, plan)
            self.assertEqual(dispatch.call_count, 1)


if __name__ == '__main__':
    unittest.main()
