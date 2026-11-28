"""Fixture identity must match both the import journal and saved receipt."""
import json
import unittest

from cloud_group_fixture import Journal, SERVICE, binding
from synthetic_epub_trial import SERVICE as ORIGINAL_SERVICE
from synthetic_format_trial import TargetReceipt
from test_personal_upload_trial import FakeProbe
from test_secure_native_session import Backend, credentials
from verify_synthetic_epub_upload import run


class FixtureBindingTest(unittest.TestCase):
    def test_binding_and_tampering(self):
        self.assertNotEqual(SERVICE, ORIGINAL_SERVICE)
        upload = Journal(Backend()); receipt_backend = Backend()
        receipt = TargetReceipt('epub', backend=receipt_backend, scope='group-fixture')
        result = run(FakeProbe(), upload, credentials(), lambda _:True, lambda _:True, apply=True,
                     sleep=lambda _:None, now=lambda:1000, notify_receipt=receipt.record, cleanup_gate=lambda *_:False)
        self.assertEqual(result['phase'], 'imported')
        state, token = binding(upload, receipt_backend)
        self.assertEqual(state['phase'], 'imported'); self.assertEqual(token, upload.read()[1])
        original = receipt_backend.load(); value = json.loads(original)
        for key, bad in (('schema', True), ('target', 'CB_other'), ('attempt', '0'*32),
                         ('owner', '123'), ('plan_sha256', '0'*64)):
            changed = dict(value); changed[key] = bad; receipt_backend.save(json.dumps(changed).encode())
            with self.subTest(key=key), self.assertRaises(ValueError): binding(upload, receipt_backend)
        receipt_backend.save(original)
        self.assertEqual(binding(upload, receipt_backend)[0]['target'], state['target'])

    def test_scope_only_supports_epub_and_rejects_missing_receipt(self):
        with self.assertRaises(ValueError): TargetReceipt('pdf', backend=Backend(), scope='group-fixture')
        with self.assertRaises(ValueError): binding(Journal(Backend()), Backend())


if __name__ == '__main__': unittest.main()
