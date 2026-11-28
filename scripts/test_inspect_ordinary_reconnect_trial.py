import contextlib
import io
import json
import unittest
from unittest.mock import patch

import inspect_ordinary_reconnect_trial as task


class InspectionTests(unittest.TestCase):
    def test_default_does_not_open_credentials_or_network(self):
        with patch.object(task,'SessionStore') as session,patch.object(task,'OrdinaryReconnectStore') as journal, \
             contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        session.assert_not_called();journal.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_unretired_intent_stops_before_credentials(self):
        for state in (None,{'phase':'prepared','posts':0},{'phase':'restore_pending','posts':3}):
            with self.subTest(state=state),patch.object(task,'OrdinaryReconnectStore') as journal, \
                 patch.object(task,'SessionStore') as session,contextlib.redirect_stdout(io.StringIO()) as out:
                journal.return_value.read.return_value=(state,None)
                self.assertEqual(task.main(['--saved-session']),1)
            session.assert_not_called();self.assertEqual(json.loads(out.getvalue())['reason'],'ordinary_inspect/intent')

    def test_retry_requires_saved_session(self):
        with contextlib.redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):task.main(['--retry'])


if __name__=='__main__':unittest.main()
