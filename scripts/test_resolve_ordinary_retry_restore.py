import contextlib
import io
import json
import unittest
from unittest.mock import patch

import resolve_ordinary_retry_restore as task


class ResolveTests(unittest.TestCase):
    def test_default_is_offline_and_requires_explicit_mode(self):
        with patch.object(task,'SessionStore') as session,contextlib.redirect_stdout(io.StringIO()) as out:self.assertEqual(task.main([]),0)
        session.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')
        for args in (['--resolve'],['--saved-session']):
            with contextlib.redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):task.main(args)
    def test_unrelated_or_unfinished_state_stops_before_credentials(self):
        for state in (None,{'phase':'position_pending','posts':2},{'phase':'retired','posts':3}):
            with self.subTest(state=state),patch.object(task,'OrdinaryReconnectRetryStore') as original, \
                 patch.object(task,'RetryRecoveryRenewalStore') as bridge,patch.object(task,'RestoreReadbackStore') as proof, \
                 patch.object(task,'SessionStore') as session,contextlib.redirect_stdout(io.StringIO()) as out:
                original.return_value.read.return_value=(state,None);bridge.return_value.read.return_value=(None,None);proof.return_value.read.return_value=(None,None)
                self.assertEqual(task.main(['--saved-session','--resolve']),1)
            session.assert_not_called();self.assertEqual(json.loads(out.getvalue())['reason'],'ordinary_restore_readback/intent')


if __name__=='__main__':unittest.main()
