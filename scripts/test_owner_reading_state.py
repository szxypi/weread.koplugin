"""Offline synthetic tests for private pipe and independent comparison."""
from copy import deepcopy
from types import SimpleNamespace
import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

from verify_owner_reading_state import inspect, main


class Probe:
    def __init__(self):
        self.allowed = set()
        self.shelves = 0
        self.shelf_data = {'books': [{'bookId': '990099', 'title': 'Synthetic one'},
                                     {'bookId': 'CB_synthetic', 'title': 'Synthetic two'}], 'archive': []}
    def shelf(self, _credentials):
        self.shelves += 1
        return deepcopy(self.shelf_data)
    def progress(self, _credentials, identity):
        assert identity in self.allowed
        return {'book': {'bookId': identity, 'isStartReading': int(identity.startswith('CB_'))}}


class OwnerReadingStateTests(unittest.TestCase):
    def test_pipe_comparison_does_not_return_private_inputs(self):
        probe = Probe()
        credentials = {'vid': '880088', 'accessToken': 'private-sentinel'}
        result = SimpleNamespace(returncode=0, stdout=b'\nWEREAD_OWNER_READING_STATE={"model":[false,true],"native":[false,true],"requests":2}\n')
        with patch('verify_owner_reading_state.subprocess.run', return_value=result) as child:
            report = inspect({'vid': '880088'}, credentials, probe, ['synthetic-command'])
        self.assertEqual(report['result'], 'OWNER_READ_ONLY_VERIFIED')
        self.assertEqual(probe.shelves, 2)
        self.assertEqual(json.loads(child.call_args.kwargs['input'])['credentials'], credentials)
        for private in ('990099', 'CB_synthetic', 'private-sentinel', '880088'):
            self.assertNotIn(private, json.dumps(report))

    def test_mismatched_lua_observation_cannot_pass(self):
        result = SimpleNamespace(returncode=0, stdout=b'\nWEREAD_OWNER_READING_STATE={"model":[false,true],"native":[true,true],"requests":2}\n')
        with patch('verify_owner_reading_state.subprocess.run', return_value=result):
            with self.assertRaises(ValueError):
                inspect({'vid': '880088'}, {'vid': '880088'}, Probe(), ['synthetic-command'])

    def test_full_ui_mode_selects_requested_kind_and_requires_ui_proof(self):
        result = SimpleNamespace(returncode=0, stdout=b'\nWEREAD_OWNER_READING_STATE={"model":[true],"native":[true],"requests":1,"ui":true}\n')
        with patch('verify_owner_reading_state.subprocess.run', return_value=result) as child:
            report = inspect({'vid': '880088'}, {'vid': '880088'}, Probe(), ['synthetic-command'], ui_kind='imported')
        self.assertTrue(report['full_plugin_ui_verified'])
        self.assertEqual((report['ordinary_books'], report['imported_books']), (0, 1))
        self.assertEqual(len(json.loads(child.call_args.kwargs['input'])['samples']), 1)
        result.stdout = b'\nWEREAD_OWNER_READING_STATE={"model":[true],"native":[true],"requests":1}\n'
        with patch('verify_owner_reading_state.subprocess.run', return_value=result):
            with self.assertRaises(ValueError):
                inspect({'vid': '880088'}, {'vid': '880088'}, Probe(), ['synthetic-command'], ui_kind='imported')

    def test_change_contract_requires_separate_proof_and_in_memory_shelf(self):
        result = SimpleNamespace(returncode=0, stdout=b'\nWEREAD_OWNER_READING_STATE={"model":[false,true],"native":[false,true],"requests":2,"contract":true}\n')
        with patch('verify_owner_reading_state.subprocess.run', return_value=result) as child:
            report = inspect({'vid': '880088'}, {'vid': '880088'}, Probe(), ['synthetic-command'], contract=True)
        self.assertTrue(report['change_plan_verified'])
        self.assertIn('shelf', json.loads(child.call_args.kwargs['input']))
        result.stdout = b'\nWEREAD_OWNER_READING_STATE={"model":[false,true],"native":[false,true],"requests":2}\n'
        with patch('verify_owner_reading_state.subprocess.run', return_value=result):
            with self.assertRaises(ValueError):
                inspect({'vid': '880088'}, {'vid': '880088'}, Probe(), ['synthetic-command'], contract=True)

    def test_offline_does_not_load_credentials(self):
        with patch('verify_owner_reading_state.SessionStore') as store:
            self.assertEqual(main([]), 0)
        store.assert_not_called()

    def test_ui_runner_failure_still_emits_framed_nonprivate_result(self):
        script = Path(__file__).with_name('run_owner_reading_state_ui.py')
        child = subprocess.run([sys.executable, str(script), '--koreader', '/nonexistent'], input=b'',
                               capture_output=True, timeout=15)
        frame = b'\nWEREAD_OWNER_READING_STATE='
        self.assertNotEqual(child.returncode, 0)
        self.assertEqual(child.stdout.count(frame), 1)
        self.assertEqual(json.loads(child.stdout.split(frame)[1])['error'], 'ui_runner_failed')


if __name__ == '__main__':
    unittest.main()
