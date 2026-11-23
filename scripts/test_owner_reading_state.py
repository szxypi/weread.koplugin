"""Offline synthetic tests for private pipe and independent comparison."""
from copy import deepcopy
from types import SimpleNamespace
import json
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

    def test_offline_does_not_load_credentials(self):
        with patch('verify_owner_reading_state.SessionStore') as store:
            self.assertEqual(main([]), 0)
        store.assert_not_called()


if __name__ == '__main__':
    unittest.main()
