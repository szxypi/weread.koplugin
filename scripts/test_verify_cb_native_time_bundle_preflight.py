"""The preflight CLI never accesses a session without explicit capture mode."""
from contextlib import redirect_stdout
import io,json,unittest
from unittest.mock import Mock,patch
import verify_cb_native_time_bundle_preflight as task


class PreflightCLITests(unittest.TestCase):
    def test_default_offline(self):
        with patch.object(task,'SessionStore') as session,patch.object(task,'store') as store,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        session.assert_not_called();store.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')
    def test_explicit_result_releases_private_packet(self):
        for result,code in (('NOT_YET_HISTORICAL',0),('CB_CROSS_DAY_READONLY_VERIFIED',0),('UNVERIFIED',1)):
            packet=Mock() if result=='CB_CROSS_DAY_READONLY_VERIFIED' else None
            with self.subTest(result=result),patch.object(task,'store'),patch.object(task,'SessionStore'),patch.object(task,'NativeSessionStore'),\
                 patch.object(task,'DispatchGate'),patch.object(task,'AuditStore'),patch.object(task,'run',return_value=({'result':result},packet)),redirect_stdout(io.StringIO()):
                self.assertEqual(task.main(['--saved-capture']),code)
            if packet:packet.close.assert_called_once()


if __name__=='__main__':unittest.main()
