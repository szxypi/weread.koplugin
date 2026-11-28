"""Offline tests for single-use cleanup after verified fixture recovery."""
from copy import deepcopy
import unittest

from cloud_group_fixture import binding
from native_direct_time_trial_store import Intent
from reading_status_fixture_cleanup import run
from reading_status_fixture_trial import request
from test_reading_status_recovery import baseline, setup
from test_secure_native_session import Backend


class CleanupTests(unittest.TestCase):
    def setup_case(self):
        upload, receipt, state, mark, restore = setup()
        marked, _ = mark.read()
        restore.claim({'selection': marked['plan']['selection'], 'record': {'kind': 'restore'},
                       'body': request(state['target'], True), 'baseline': {'snapshot_hash': 'a' * 64}})
        cleanup = Intent(backend=Backend())
        return upload, receipt, state, mark, restore, cleanup

    def test_preview_and_success_remove_only_once(self):
        upload, receipt, state, mark, restore, cleanup = self.setup_case()
        sent = []
        def remove(token):
            self.assertEqual(upload.read()[0]['phase'], 'cleanup_pending')
            self.assertEqual(cleanup.read()[0]['phase'], 'claimed')
            sent.append(token)
            return {'succ': 1}
        args = (upload, mark, restore, cleanup, lambda: binding(upload, receipt.backend), lambda: True,
                lambda: True, lambda _: deepcopy(baseline()), remove, lambda _: True)
        self.assertEqual(run(*args)['result'], 'READ_ONLY_PREVIEW')
        self.assertEqual(sent, [])
        result = run(*args, apply=True, sleep=lambda _: None)
        self.assertEqual(result['result'], 'CLEANED')
        self.assertEqual(upload.read()[0]['phase'], 'restored')
        self.assertEqual(len(sent), 1)
        self.assertEqual(run(*args, apply=True)['cleanup_posts'], 0)
        self.assertEqual(len(sent), 1)

    def test_unknown_receipt_never_repeats(self):
        upload, receipt, _, mark, restore, cleanup = self.setup_case()
        sent = []
        def remove(_):
            sent.append(1)
            raise TimeoutError()
        args = (upload, mark, restore, cleanup, lambda: binding(upload, receipt.backend), lambda: True,
                lambda: True, lambda _: deepcopy(baseline()), remove, lambda _: True)
        result = run(*args, apply=True)
        self.assertEqual(result['result'], 'CLEANED_ACK_UNKNOWN')
        self.assertEqual(upload.read()[0]['phase'], 'cleanup_pending')
        self.assertEqual(run(*args, apply=True)['cleanup_posts'], 0)
        self.assertEqual(sent, [1])

    def test_changed_status_or_missing_restore_prevents_cleanup(self):
        upload, receipt, _, mark, restore, cleanup = self.setup_case()
        changed = baseline()
        changed['progress']['flag'] = 1
        args = (upload, mark, restore, cleanup, lambda: binding(upload, receipt.backend), lambda: True,
                lambda: True, lambda _: deepcopy(changed), lambda _: self.fail('unexpected remove'), lambda _: True)
        self.assertEqual(run(*args, apply=True)['cleanup_posts'], 0)
        self.assertIsNone(cleanup.read()[0])
        self.assertEqual(upload.read()[0]['phase'], 'imported')


if __name__ == '__main__':
    unittest.main()
