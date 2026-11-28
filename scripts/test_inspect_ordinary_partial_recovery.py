import contextlib
import io
import json
import unittest
from unittest.mock import patch

import inspect_ordinary_partial_recovery as task


class InspectTests(unittest.TestCase):
    def test_default_offline_without_credentials(self):
        with patch.object(task,'SessionStore') as session,patch.object(task,'OrdinaryReconnectStore') as original, \
             contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        session.assert_not_called();original.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')
    def test_unfinished_or_unknown_stops_before_credentials(self):
        for state in (None,{'phase':'enter_acknowledged','posts':1},{'phase':'partial_restored','posts':2}):
            with self.subTest(state=state),patch.object(task,'OrdinaryReconnectStore') as original, \
                 patch.object(task,'PartialRecoveryStore') as recovery,patch.object(task,'RecoveryRenewalStore') as bridge, \
                 patch.object(task,'SessionStore') as session,contextlib.redirect_stdout(io.StringIO()) as out:
                original.return_value.read.return_value=(state,None);recovery.return_value.read.return_value=(None,None);bridge.return_value.read.return_value=(None,None)
                self.assertEqual(task.main(['--saved-session']),1)
            session.assert_not_called();self.assertEqual(json.loads(out.getvalue())['reason'],'ordinary_partial_inspect/intent')
    def test_retry_requires_saved_session(self):
        with contextlib.redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):task.main(['--retry'])


if __name__=='__main__':unittest.main()
