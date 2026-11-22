import contextlib
import io
import json
import unittest
from unittest.mock import patch

import verify_ordinary_reconnect_rpc_preview as task


class PreviewTests(unittest.TestCase):
    def test_default_is_offline_and_does_not_load_credentials(self):
        with patch.object(task, 'SessionStore') as session, patch.object(task, 'NativeSessionStore') as native, \
             patch.object(task, 'manual_command') as command, contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]), 0)
        self.assertEqual(json.loads(out.getvalue())['result'], 'OFFLINE_ONLY')
        session.assert_not_called(); native.assert_not_called(); command.assert_not_called()

    def test_write_modes_require_saved_session_and_invalid_dimensions_fail(self):
        for options in (['--apply'], ['--prepare'], ['--saved-session','--prepare','--apply'], ['--width', '0']):
            with self.subTest(options=options), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                task.main(options)

    def test_missing_or_consumed_intent_stops_before_credentials_and_runner(self):
        for options,state in ((['--saved-session','--apply'],None),(['--saved-session','--prepare'],{'phase':'retired'})):
            with self.subTest(options=options), patch.object(task,'OrdinaryReconnectStore') as journal, \
                 patch.object(task,'SessionStore') as session, patch.object(task,'manual_command') as runner, \
                 contextlib.redirect_stdout(io.StringIO()) as out:
                journal.return_value.read.return_value=(state,None)
                self.assertEqual(task.main(options),1)
            session.assert_not_called();runner.assert_not_called()
            result=json.loads(out.getvalue())
            self.assertEqual(result['result'],'UNVERIFIED');self.assertEqual(result['account_data_posts'],0)

    def test_difference_paths_hide_user_data(self):
        first={'books':[{'bookId':'private-id','private-title':'old','updateTime':1}],'synckey':1}
        later={'books':[{'bookId':'another-id','private-title':'new','updateTime':2}],'synckey':2}
        paths=task.shelf_difference_paths(first,later)
        self.assertIn('/synckey',paths);self.assertIn('/books/*/updateTime',paths)
        self.assertNotIn('private',str(paths));self.assertNotIn('another',str(paths))

    def test_shelf_comparison_ignores_only_nondecreasing_bounded_lecture_cursor(self):
        before={'books':[{'bookId':'1','title':'same'}],'lectureSynckey':100}
        self.assertTrue(task.same_shelf(before,{'books':[{'bookId':'1','title':'same'}],'lectureSynckey':101}))
        for other in ({'books':[{'bookId':'1','title':'different'}],'lectureSynckey':101},
                      {'books':[{'bookId':'1','title':'same'}],'lectureSynckey':99},
                      {'books':[{'bookId':'1','title':'same'}],'lectureSynckey':True},
                      {'books':[{'bookId':'1','title':'same'}]}):
            with self.subTest(other=other):self.assertFalse(task.same_shelf(before,other))


if __name__ == '__main__': unittest.main()
