"""No real account, Keychain or network is used by these tests."""
from contextlib import redirect_stdout
import io
import json
import unittest
from unittest.mock import patch

from verify_reading_state import ReadOnlyProbe, inspect, main, observation, zero_or_nonzero


class ReadingStateTests(unittest.TestCase):
    def test_unknown_and_conflicting_data_are_not_guessed(self):
        self.assertEqual(observation({'book': {'isStartReading': 0, 'chapterUid': 8,
                                               'startReadingTime': 10}}, '42', 0),
                         'started=0;chapter=nonzero;time=nonzero;finished=0')
        self.assertEqual(observation({'book': {'isStartReading': True}}, '42', None),
                         'started=unknown;chapter=unknown;time=unknown;finished=unknown')
        for value in (True, -1, float('nan'), float('inf'), '0', None):
            self.assertEqual(zero_or_nonzero(value), 'unknown')
        for value in ({}, {'book': {'bookId': '43'}}, {'bookId': '43', 'book': {}}):
            with self.assertRaises(ValueError):
                observation(value, '42', 0)

    def test_offline_default_does_not_open_keychain_or_network(self):
        with patch('verify_reading_state.SessionStore') as store, \
             patch('verify_reading_state.ReadOnlyProbe') as probe, redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main([]), 0)
        store.assert_not_called()
        probe.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'], 'OFFLINE_ONLY')

    def test_only_scoped_gets_and_no_repeat(self):
        probe = ReadOnlyProbe()
        probe.allowed = {'42'}
        with patch('verify_eink_login.NativeProbe.request', return_value={}) as request:
            probe.progress({}, '42')
            self.assertEqual(request.call_args.kwargs['credentials'], {})
            self.assertNotIn('body', request.call_args.kwargs)
            for identity in ('42', '43'):
                with self.assertRaises(ValueError):
                    probe.progress({}, identity)
            with self.assertRaises(ValueError):
                probe.request('anything', 'https://example.com', body={})
            probe.shelf({})
            probe.shelf({})
            with self.assertRaises(ValueError):
                probe.shelf({})
            self.assertEqual(request.call_count, 3)

    def test_aggregate_only_and_shelf_change_stops(self):
        class Probe:
            def __init__(self):
                self.n = 0
                self.allowed = set()
            def shelf(self, _):
                self.n += 1
                return {'books': [{'bookId': '990099', 'finishReading': 0}]}
            def progress(self, _, identity):
                self.assertion = identity in self.allowed
                return {'book': {'bookId': identity, 'isStartReading': 0, 'chapterUid': 1,
                                 'startReadingTime': 100}}
        with patch('verify_reading_state.project', return_value={'same': True}):
            probe = Probe()
            result = inspect(probe, {'vid': 'private-owner'}, sample=1)
        self.assertTrue(probe.assertion)
        self.assertEqual(result['sampled'], 1)
        for private in ('990099', 'private-owner', '100'):
            self.assertNotIn(private, json.dumps(result))
        with patch('verify_reading_state.project', side_effect=[{'before': 1}, {'after': 2}]):
            with self.assertRaises(ValueError):
                inspect(Probe(), {}, sample=1)
        for sample in (0, 31, True):
            with self.assertRaises(ValueError):
                inspect(Probe(), {}, sample=sample)


if __name__ == '__main__':
    unittest.main()
