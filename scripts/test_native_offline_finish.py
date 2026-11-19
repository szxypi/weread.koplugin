"""The real-account driver cannot write before same-plan dry-run succeeds."""
import unittest
from unittest.mock import Mock
from verify_native_offline_finish import execute


class OfflineFinishTests(unittest.TestCase):
    def test_same_probe_and_credentials_used_for_both_runs(self):
        probe=Mock();credentials={'vid':'synthetic'};store=Mock();store.pending.return_value=False
        runner=Mock(side_effect=[{'result':'PASS','account_data_posts':0},
                                 {'result':'PASS','account_data_posts':2,'independent_steps':2}])
        current=Mock();execute(probe,credentials,store,['runner','--offline-queue'],current,runner)
        self.assertEqual(runner.call_count,2)
        self.assertIs(runner.call_args_list[0].args[0],probe);self.assertIs(runner.call_args_list[1].args[0],probe)
        self.assertIs(runner.call_args_list[0].args[1],credentials);self.assertIs(runner.call_args_list[1].args[1],credentials)
        self.assertFalse(runner.call_args_list[0].kwargs['armed']);self.assertTrue(runner.call_args_list[1].kwargs['armed'])
        self.assertEqual(runner.call_args_list[1].args[3],['runner','--offline-queue','--armed'])
        current.assert_called_once();probe.read.assert_called_once_with(credentials,False)

    def test_failed_dry_run_never_invokes_write(self):
        for value in ({'result':'UNVERIFIED','account_data_posts':0},{'result':'PASS','account_data_posts':1}):
            runner=Mock(return_value=value);store=Mock();store.pending.return_value=False
            with self.assertRaises(ValueError):execute(Mock(),{},store,['runner','--offline-queue'],Mock(),runner)
            self.assertEqual(runner.call_count,1)

    def test_rejects_unscoped_or_already_armed_runner(self):
        for command in ([],['runner'],['runner','--offline-queue','--armed'],['runner','--offline-queue','--mock-port'],
                        ['runner','--offline-queue','--mock-port=1234']):
            runner=Mock()
            with self.assertRaises(ValueError):execute(Mock(),{},Mock(),command,Mock(),runner)
            runner.assert_not_called()


if __name__=='__main__':unittest.main()
