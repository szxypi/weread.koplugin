"""Default invocation is offline; the extra marker is permanent."""
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from verify_cloud_group_nonempty import main, reserve_once


class EntryTest(unittest.TestCase):
    def test_offline_default_never_opens_session(self):
        with patch('verify_cloud_group_nonempty.SessionStore') as session,contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(main([]),0);session.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def test_permanent_claim_cannot_be_reused(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'claim.json';reserve_once(path);before=path.read_bytes()
            with self.assertRaises(FileExistsError):reserve_once(path)
            self.assertEqual(path.read_bytes(),before)


if __name__=='__main__':unittest.main()
