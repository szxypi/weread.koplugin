import copy
from contextlib import redirect_stdout
import io
import json
import time
import unittest

from cb_fixture_native_time_intent import Intent
from cb_fixture_web_time_evidence import Evidence
from test_cb_fixture_position_transport import MemoryBackend
from test_cb_txt_manual_fixture_ui_trial import Harness as ManualHarness
from verify_readtime_upload import expected_statistics
import verify_cb_txt_native_time_fixture_ui_trial as task


class Harness(ManualHarness):
    def __init__(self, fail=None):
        super().__init__(fail)
        self.current['updateTime'] = 1
        self.context['initial_observed'] = self.project()
        self.intent = Intent(backend=MemoryBackend())
        self.evidences = [Evidence(backend=MemoryBackend()), Evidence(backend=MemoryBackend())]
        self.now = int(time.time())
        self.stats_value = dict(baseTime=0, readTimes={}, totalReadTime=0, readDays=0)
    def stats(self): return copy.deepcopy(self.stats_value)
    def progress(self): return self.pair()[0]
    def runner(self, _command, payload, width, _height, _dpi):
        self.calls.append((payload['armed'], width))
        if self.fail == 'dry' and not payload['armed']: raise ValueError('dry')
        if payload['armed']:
            self.current['readingTime'] += 10
            self.stats_value = expected_statistics(self.stats_value, self.now, 10, time_zone='+08:00')
            if self.fail == 'armed': raise ValueError('unknown')
        return True
    def execute(self):
        return task.time_trial(self.context, self.report, self.intent, self.evidences, ['manual'], self,
                               runner=self.runner, attest=lambda: ['manual'], clock=lambda: self.now, sleep=lambda _: None)


class TxtNativeTimeTrialTest(unittest.TestCase):
    def test_two_scoped_reports_and_statistics(self):
        h = Harness(); self.assertTrue(h.execute())
        self.assertEqual(h.calls, [(False, 600), (True, 600), (False, 1264), (True, 1264)])
        self.assertEqual(h.report['position_writes_known'], 7)
        self.assertFalse(h.report['position_writes_uncertain'])
        self.assertEqual(len(h.report['time_stages']), 2)
        self.assertEqual(h.current['readingTime'], 20)
        self.assertEqual(h.stats_value['totalReadTime'], 20)

    def test_unknown_result_is_not_replayed(self):
        for failure, uncertain in (('dry', False), ('armed', True)):
            h = Harness(failure)
            with self.assertRaises(ValueError): h.execute()
            self.assertEqual(h.report['position_writes_uncertain'], uncertain)
            self.assertEqual(len(h.calls), 1 if failure == 'dry' else 2)
            with self.assertRaises(Exception): h.execute()

    def test_changed_shelf_or_count_prevents_write(self):
        h = Harness(); h.context['shelf_current'] = lambda: False
        self.assertFalse(h.execute()); self.assertEqual(h.calls, [])
        h = Harness(); h.current['readingTime'] = 1
        with self.assertRaises(ValueError): h.execute()
        self.assertEqual(h.calls, [])

    def test_dry_run_stat_change_prevents_write(self):
        h = Harness()
        def runner(*args):
            result = h.runner(*args)
            if not args[1]['armed']: h.stats_value['totalReadTime'] += 1
            return result
        self.assertFalse(task.time_trial(h.context, h.report, h.intent, h.evidences, ['manual'], h,
                                        runner=runner, attest=lambda: ['manual'], clock=lambda: h.now))
        self.assertEqual(h.calls, [(False, 600)])

    def test_unrecognized_statistics_stops_without_second_report(self):
        h = Harness()
        def runner(*args):
            result = h.runner(*args)
            if args[1]['armed']: h.stats_value['totalReadTime'] += 1
            return result
        self.assertFalse(task.time_trial(h.context, h.report, h.intent, h.evidences, ['manual'], h,
                                        runner=runner, attest=lambda: ['manual'], clock=lambda: h.now, sleep=lambda _: None))
        self.assertEqual(h.calls, [(False, 600), (True, 600)])
        self.assertEqual(len(h.report['time_stages']), 0)

    def test_offline_and_consumed_scope(self):
        with redirect_stdout(io.StringIO()) as output: self.assertEqual(task.main([]), 0)
        self.assertEqual(json.loads(output.getvalue())['result'], 'OFFLINE_ONLY')
        h = Harness(); h.evidences[0].backend.save(b'occupied')
        result = task.execute({}, None, None, {}, None, None, None, h.intent, *h.evidences, [], [],
                              first=lambda *_a, **_kw: self.fail('unexpected'))
        self.assertEqual(result['account_data_writes_known'], 0)


if __name__ == '__main__': unittest.main()
