"""Fresh capture must never overwrite or grant access to older evidence."""
from contextlib import nullcontext, redirect_stderr
import io
import unittest
from unittest.mock import patch

import native_time_capture_bundle as old
import native_time_capture_fresh_bundle as fresh
from secure_weread_session import StoreError
from test_native_time_capture_bundle import fixture
from test_secure_native_session import Backend
import verify_native_time_capture


class FreshCaptureTests(unittest.TestCase):
    def test_fresh_slot_is_independent_and_one_use(self):
        plan, evidence, _, _, _ = fixture()
        entries = {}

        def backend(*, service, account):
            self.assertEqual(account, fresh.ACCOUNT)
            return entries.setdefault(service, Backend())

        with patch.object(old, 'MacKeychain', backend), patch.object(fresh, 'MacKeychain', backend), \
             patch.object(old, 'project_lock', lambda *_: nullcontext()), \
             patch.object(fresh, 'project_lock', lambda *_: nullcontext()):
            previous = old.CaptureBundleStore()
            previous.capture(plan, evidence)
            old_snapshot = previous.read()
            new = fresh.store()
            self.assertNotEqual(old.SERVICE, fresh.SERVICE)
            self.assertEqual(new.read(), (None, None))
            receipt = new.capture(plan, evidence)
            self.assertEqual(fresh.store().read()[1], receipt)
            self.assertEqual(previous.read(), old_snapshot)
            with self.assertRaises(StoreError):
                new.capture(plan, evidence)
            entries[fresh.SERVICE + '.part-1'].data = b'corrupted'
            with self.assertRaises(StoreError):
                fresh.store().read()
            self.assertEqual(previous.read(), old_snapshot)
            for method in ('claim', 'send', 'advance', 'delete', 'renew'):
                self.assertFalse(hasattr(new, method))

    def test_new_slot_requires_explicit_evidence_and_capture(self):
        for args in (['--fresh-bundle'],
                     ['--mock', '--capture', '--fresh-bundle', '--native-ui-command', 'unused']):
            with self.subTest(args=args), redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                verify_native_time_capture.main(args)


if __name__ == '__main__':
    unittest.main()
