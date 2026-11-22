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

    def test_no_write_mode_and_invalid_dimensions(self):
        for options in (['--apply'], ['--saved-session', '--apply'], ['--width', '0']):
            with self.subTest(options=options), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                task.main(options)


if __name__ == '__main__': unittest.main()
