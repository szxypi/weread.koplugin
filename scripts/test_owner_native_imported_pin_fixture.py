import io
import json
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

import verify_owner_native_imported_pin_fixture as task


class NativeImportedFixtureCliTests(unittest.TestCase):
    def test_default_is_offline(self):
        with patch.object(task,'SessionStore') as session,patch.object(task,'NativeSessionStore') as native,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]),0)
        session.assert_not_called();native.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['account_data_writes'],0)
    def test_apply_requires_explicit_imported_command_without_armed_flag(self):
        for arguments in (['--apply'],['--saved-session','--apply'],
                          ['--saved-session','--apply','--native-command','synthetic'],
                          ['--saved-session','--apply','--native-command','synthetic','--imported','--armed'],
                          ['--saved-session','--native-command','synthetic','--imported']):
            with self.subTest(arguments=arguments),self.assertRaises(SystemExit):task.main(arguments)


if __name__=='__main__':unittest.main()
