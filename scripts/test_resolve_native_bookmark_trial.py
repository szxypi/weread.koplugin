from contextlib import redirect_stdout
import io
import json
import unittest
from unittest.mock import patch

from resolve_native_bookmark_trial import main


class NativeBookmarkRecoveryEntryTests(unittest.TestCase):
    def test_offline_default_opens_no_account_or_keychain(self):
        output=io.StringIO()
        with patch('resolve_native_bookmark_trial.SessionStore') as session, \
             patch('resolve_native_bookmark_trial.BookmarkTrialStore') as journal,redirect_stdout(output):
            self.assertEqual(main([]),0)
        session.assert_not_called();journal.assert_not_called()
        self.assertEqual(json.loads(output.getvalue()),{'result':'OFFLINE_ONLY','account_data_posts':0,'authentication_posts':0})

    def test_other_pending_intent_blocks_before_session_or_dispatch(self):
        output=io.StringIO()
        with patch('resolve_native_bookmark_trial.other_pending',return_value=True) as other, \
             patch('resolve_native_bookmark_trial.SessionStore') as session, \
             patch('resolve_native_bookmark_trial.BookmarkTrialStore') as journal,redirect_stdout(output):
            journal.return_value.read.return_value=(None,None)
            self.assertEqual(main(['--saved-session','--expected-intent','0'*64,'--resume-delete']),1)
        other.assert_called_once_with(exclude_native_bookmark=True);session.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['account_data_posts'],0)


if __name__=='__main__':unittest.main()
