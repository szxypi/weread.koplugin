from contextlib import redirect_stdout
import io
import json
import unittest
from unittest.mock import patch

from personal_upload_trial import hash_value
from secure_shelf_experiment import canonical
import verify_cb_txt_initial_fixture_trial as task


class Backend:
    def __init__(self, data=None): self.data = data
    def load(self): return self.data


class Receipt:
    def __init__(self): self.backend = Backend()
    def record(self, *_args): pass


class Journal:
    def __init__(self):
        self.state = dict(phase='imported', target='CB_Synthetic', attempt='a' * 32,
                          plan=dict(owner='123456', name='synthetic'))
        self.receipt = object()
    def read(self): return self.state, self.receipt


class TxtInitialTrialTest(unittest.TestCase):
    def test_offline_default_does_not_load_credentials(self):
        with patch.object(task, 'SessionStore') as session, redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]), 0)
        session.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'], 'OFFLINE_ONLY')

    def test_consumed_receipt_prevents_even_the_trial(self):
        receipt = Receipt(); receipt.backend.data = b'consumed'
        result = task.execute({}, None, None, {}, Journal(), receipt, None,
                              trial=lambda *_args, **_kwargs: self.fail('trial called'))
        self.assertEqual(result['result'], 'UNVERIFIED')
        self.assertEqual(result['account_data_writes_known'], 0)

    def test_exact_fixture_receipt_and_scoped_txt_upload(self):
        journal, receipt, grant = Journal(), Receipt(), {'vid': '123456'}
        receipt.backend.data = canonical(dict(schema=1, owner='123456', attempt=journal.state['attempt'],
                                              target=journal.state['target'], plan_sha256=hash_value(journal.state['plan'])))
        captured = {}
        def trial(*_args, **kwargs):
            guard = kwargs['fixture_authorized']
            self.assertTrue(guard(journal, journal.receipt, journal.state['target'], '123456'))
            self.assertFalse(guard(journal, object(), journal.state['target'], '123456'))
            self.assertFalse(guard(journal, journal.receipt, 'CB_Other', '123456'))
            receipt.backend.data += b' '
            self.assertFalse(guard(journal, journal.receipt, journal.state['target'], '123456'))
            receipt.backend.data = None
            self.assertEqual(kwargs['source_format'], 'web_txt')
            kwargs['uploader'](None, journal, grant, lambda _: True, lambda _: True,
                               apply=False, cleanup_gate=lambda *_: True)
            return dict(result='CB_INITIAL_FIXTURE_VERIFIED')
        def upload(*_args, **kwargs):
            captured.update(kwargs)
            return dict(result='READ_ONLY_PREVIEW')
        # The entry guard must see an unused receipt; the mocked upload binds it
        # before the shared coordinator invokes fixture_authorized.
        original = receipt.backend.data; receipt.backend.data = None
        def staged_trial(*args, **kwargs):
            receipt.backend.data = original
            return trial(*args, **kwargs)
        result = task.execute({}, None, None, grant, journal, receipt, None, trial=staged_trial, upload=upload)
        self.assertEqual(result['result'], 'CB_TXT_INITIAL_FIXTURE_VERIFIED')
        self.assertEqual(captured['fixture_extension'], 'txt')
        self.assertEqual(captured['fixture_builder'](), task.BODY)
        self.assertFalse(captured['apply'])
        self.assertEqual(captured['notify_receipt'], receipt.record)

    def test_exception_during_apply_reports_unknown_not_zero(self):
        with patch.object(task, 'SessionStore', side_effect=RuntimeError), redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main(['--saved-session', '--apply']), 1)
        value = json.loads(output.getvalue())
        self.assertIsNone(value['account_data_writes_known'])
        self.assertTrue(value['position_writes_uncertain'])


if __name__ == '__main__': unittest.main()
