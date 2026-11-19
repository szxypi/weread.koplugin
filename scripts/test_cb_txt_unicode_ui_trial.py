from contextlib import redirect_stdout
import io
import json
import unittest
from unittest.mock import patch

from personal_upload_trial import hash_value
from secure_shelf_experiment import canonical
from test_cb_txt_initial_fixture_trial import Journal, Receipt
from test_cb_fixture_position_transport import MemoryBackend
from cb_existing_position_intent import Intent
import verify_cb_txt_unicode_ui_trial as task


class UnicodeUiTrialTest(unittest.TestCase):
    def test_default_is_offline(self):
        with patch.object(task,'SessionStore') as session,patch.object(task,'ui_command') as command,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]),0)
        session.assert_not_called();command.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def test_consumed_scope_stops_before_network(self):
        receipt=Receipt();receipt.backend.data=b'consumed'
        manual=Intent(backend=MemoryBackend())
        result=task.execute({},None,None,{},Journal(),receipt,None,manual,[],[],
                            trial=lambda *_args,**_kwargs:self.fail('network trial started'))
        self.assertEqual(result['account_data_writes_known'],0)

    def test_owned_fixture_and_scoped_unicode_plan(self):
        journal,receipt,grant=Journal(),Receipt(),{'vid':'123456'}
        manual=Intent(backend=MemoryBackend());captured={}
        expected=canonical(dict(schema=1,owner='123456',attempt=journal.state['attempt'],
                                target=journal.state['target'],plan_sha256=hash_value(journal.state['plan'])))
        def upload(*_args,**kwargs):captured.update(kwargs);return dict(result='READ_ONLY_PREVIEW')
        def trial(*_args,**kwargs):
            self.assertEqual(kwargs['source_format'],'web_txt');self.assertIs(kwargs['position_planner'],task.plan)
            receipt.backend.data=expected
            self.assertTrue(kwargs['fixture_authorized'](journal,journal.receipt,journal.state['target'],'123456'))
            self.assertFalse(kwargs['fixture_authorized'](journal,object(),journal.state['target'],'123456'))
            receipt.backend.data=None
            kwargs['uploader'](None,journal,grant,lambda _:True,lambda _:True,apply=False,cleanup_gate=lambda *_:True)
            self.assertTrue(kwargs['after_verified']({'fixture':True},{}))
            return dict(result='CB_FIRST_NATIVE_UI_VERIFIED',manual_stages=[{},{}])
        result=task.execute({},None,None,grant,journal,receipt,None,manual,[],['second'],trial=trial,upload=upload,
                            manual_runner=lambda context,report,intent,command:context=={'fixture':True} and intent is manual and command==['second'])
        self.assertEqual(result['result'],'CB_TXT_UNICODE_NATIVE_UI_VERIFIED')
        self.assertEqual(captured['fixture_builder'](),task.BODY);self.assertFalse(captured['apply'])
        self.assertIn('😀',captured['fixture_builder']().decode())

    def test_apply_error_remains_uncertain(self):
        with patch.object(task,'ui_command',side_effect=RuntimeError),redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main(['--saved-session','--apply']),1)
        result=json.loads(output.getvalue())
        self.assertTrue(result['position_writes_uncertain']);self.assertIsNone(result['account_data_writes_known'])


if __name__=='__main__':unittest.main()
