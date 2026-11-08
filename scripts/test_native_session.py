"""Native session CLI uses synthetic stores only."""
from contextlib import redirect_stdout
import io
import json
import unittest
from unittest.mock import patch
from verify_native_session import main


class NativeSessionTests(unittest.TestCase):
    def test_default_never_opens_store_or_network(self):
        with patch('verify_native_session.NativeSessionStore') as native,patch('verify_native_session.SessionStore') as web,\
                patch('verify_native_session.NativeProbe') as probe,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main([]),0)
        native.assert_not_called();web.assert_not_called();probe.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_clear_is_explicit_and_only_native(self):
        with patch('verify_native_session.NativeSessionStore') as native,patch('verify_native_session.SessionStore') as web,\
                patch('verify_native_session.NativeProbe') as probe,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main(['--clear-saved-session']),0)
        native.return_value.delete.assert_called_once_with();web.assert_not_called();probe.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'],'NATIVE_SESSION_CLEARED')

    def test_read_failure_retains_both_entries_and_redacts(self):
        credentials=dict(vid='88008800',accessToken='private-access')
        with patch('verify_native_session.NativeSessionStore') as native,patch('verify_native_session.SessionStore') as web,\
                patch('verify_native_session.NativeProbe') as probe,redirect_stdout(io.StringIO()) as out:
            web.return_value.load.return_value=dict(vid='88008800')
            native.return_value.load.return_value=credentials
            probe.return_value.request.side_effect=RuntimeError('private-response')
            self.assertEqual(main(['--saved-session']),1)
        native.return_value.delete.assert_not_called();web.return_value.delete.assert_not_called()
        self.assertEqual(credentials,{})
        self.assertNotIn('private-',out.getvalue());self.assertNotIn('88008800',out.getvalue())


if __name__=='__main__':unittest.main()
