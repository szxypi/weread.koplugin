from contextlib import redirect_stdout
import io
import json
import unittest
from unittest.mock import patch

from personal_upload_trial import hash_value
from secure_shelf_experiment import canonical
from test_cb_txt_initial_fixture_trial import Journal, Receipt
import verify_cb_txt_initial_fixture_ui_trial as task


class TxtInitialUiTrialTest(unittest.TestCase):
    def test_offline_default_does_not_load_credentials_or_runtime(self):
        with patch.object(task, 'SessionStore') as session, patch.object(task, 'ui_command') as command, redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]), 0)
        session.assert_not_called(); command.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'], 'OFFLINE_ONLY')

    def test_consumed_receipt_stops_before_trial(self):
        receipt = Receipt(); receipt.backend.data = b'consumed'
        result = task.execute({}, None, None, {}, Journal(), receipt, None, [],
                              trial=lambda *_args, **_kwargs: self.fail('trial called'))
        self.assertEqual(result['result'], 'UNVERIFIED'); self.assertEqual(result['account_data_writes_known'], 0)

    def test_receipt_and_txt_payload_scope(self):
        journal, receipt, grant = Journal(), Receipt(), {'vid': '123456'}
        expected = canonical(dict(schema=1, owner='123456', attempt=journal.state['attempt'],
                                  target=journal.state['target'], plan_sha256=hash_value(journal.state['plan'])))
        captured = {}
        def trial(*_args, **kwargs):
            receipt.backend.data = expected
            guard = kwargs['fixture_authorized']
            self.assertTrue(guard(journal, journal.receipt, journal.state['target'], '123456'))
            self.assertFalse(guard(journal, object(), journal.state['target'], '123456'))
            receipt.backend.data += b' '
            self.assertFalse(guard(journal, journal.receipt, journal.state['target'], '123456'))
            receipt.backend.data = None
            self.assertEqual(kwargs['source_format'], 'web_txt')
            kwargs['uploader'](None, journal, grant, lambda _: True, lambda _: True,
                               apply=False, cleanup_gate=lambda *_: True)
            return dict(result='CB_FIRST_NATIVE_UI_VERIFIED')
        def upload(*_args, **kwargs): captured.update(kwargs); return dict(result='READ_ONLY_PREVIEW')
        result = task.execute({}, None, None, grant, journal, receipt, None, [], trial=trial, upload=upload)
        self.assertEqual(result['result'], 'CB_TXT_FIRST_NATIVE_UI_VERIFIED')
        self.assertEqual(captured['fixture_extension'], 'txt'); self.assertEqual(captured['fixture_builder'](), task.BODY)
        self.assertFalse(captured['apply']); self.assertEqual(captured['notify_receipt'], receipt.record)

    def test_unexpected_apply_exception_remains_uncertain(self):
        with patch.object(task, 'ui_command', side_effect=RuntimeError), redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main(['--saved-session', '--apply']), 1)
        result = json.loads(output.getvalue())
        self.assertTrue(result['position_writes_uncertain']); self.assertIsNone(result['account_data_writes_known'])


if __name__ == '__main__': unittest.main()
