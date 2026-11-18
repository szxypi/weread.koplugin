"""Synthetic UI supervisor stays offline unless an isolated runtime is explicit."""
from contextlib import redirect_stderr,redirect_stdout
import io,json,unittest
from unittest.mock import patch

import verify_cb_native_time_bundle_ui_rpc as task


class ImportedNativeUITests(unittest.TestCase):
    def test_default_offline_never_creates_a_process(self):
        with patch.object(task.subprocess,'Popen') as process,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        process.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')
    def test_incomplete_runtime_options_fail_before_work(self):
        for args in (['--koreader','/fake'],['--source','/fake'],['--candidate','/fake']):
            with self.subTest(args=args),patch.object(task.subprocess,'Popen') as process,redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):
                task.main(args)
            process.assert_not_called()


if __name__=='__main__':unittest.main()
