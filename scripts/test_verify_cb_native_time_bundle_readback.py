"""CLI is offline by default and cannot read the account before an ACK."""
import contextlib,io,json,unittest
from unittest.mock import Mock,patch

import verify_cb_native_time_bundle_readback as task


class ReadbackCliTests(unittest.TestCase):
    def test_default_never_opens_any_store(self):
        output=io.StringIO()
        with patch.object(task,'DispatchGate') as gate,contextlib.redirect_stdout(output):self.assertEqual(task.main([]),0)
        gate.assert_not_called();self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def test_unacknowledged_gate_never_reads_capture_or_credentials(self):
        for state in (None,{'phase':'prepared'},{'phase':'claimed'}):
            with self.subTest(state=state):
                gate=Mock();gate.read.return_value=(state,None);output=io.StringIO()
                with patch.object(task,'DispatchGate',return_value=gate),patch.object(task,'store') as store,\
                     patch.object(task,'SessionStore') as session,patch.object(task,'NativeSessionStore') as native,\
                     patch.object(task.resource,'setrlimit'),contextlib.redirect_stdout(output):
                    self.assertEqual(task.main(['--saved-capture']),0)
                store.assert_not_called();session.assert_not_called();native.assert_not_called()
                self.assertEqual(json.loads(output.getvalue())['result'],'NOT_READY')

    def test_errors_are_sanitized(self):
        output=io.StringIO()
        with patch.object(task,'DispatchGate',side_effect=ValueError('private sample')),\
             patch.object(task.resource,'setrlimit'),contextlib.redirect_stdout(output):
            self.assertEqual(task.main(['--saved-capture']),1)
        self.assertNotIn('private sample',output.getvalue());self.assertEqual(json.loads(output.getvalue())['result'],'UNVERIFIED')


if __name__=='__main__':unittest.main()
