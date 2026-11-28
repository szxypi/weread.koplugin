import io
import json
import unittest
from contextlib import redirect_stderr,redirect_stdout
from unittest.mock import patch

import verify_shelf_import_cleanup_diagnostic as task


class CliTests(unittest.TestCase):
    def test_default_is_offline(self):
        with patch.object(task,'SessionStore') as session,patch.object(task,'NativeSessionStore') as native,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        session.assert_not_called();native.assert_not_called();self.assertEqual(json.loads(out.getvalue())['account_data_writes'],0)
    def test_live_modes_require_saved_session(self):
        for flag in ('--apply','--audit','--bind-audit'):
            with self.subTest(flag=flag),redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):task.main([flag])


if __name__=='__main__':unittest.main()
