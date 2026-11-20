"""The menu integration harness must select the intended native UI workers."""
from argparse import Namespace
from pathlib import Path
import unittest
from verify_native_time_independent_ui_mock import worker_command


class UICommandTests(unittest.TestCase):
    def test_worker_modes_select_ui_and_loopback_only(self):
        args=Namespace(source=Path('/source'),candidate=Path('/candidate.zip'),koreader=Path('/runtime'))
        for live,name in ((False,'run_native_time_independent_ui_worker.py'),(True,'run_native_time_independent_ui_mock_worker.py')):
            command=worker_command(args,12345,live=live)
            self.assertEqual(command[1],'/source/scripts/'+name)
            self.assertEqual(command[command.index('--mock-port')+1],'12345')
            self.assertEqual(command[command.index('--width')+1],'1264')
            self.assertNotIn('run_native_time_guarded_worker.py',' '.join(command))


if __name__=='__main__':unittest.main()
