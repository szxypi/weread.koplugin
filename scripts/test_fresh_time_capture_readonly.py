"""The independent capture preflight cannot authorize or perform a write."""
from contextlib import redirect_stdout
from copy import deepcopy
import io
import json
import unittest
from unittest.mock import Mock, patch

from test_native_time_capture import capture
from txt_full_summary import digest
import verify_fresh_time_capture_readonly as task


class FreshReadonlyTests(unittest.TestCase):
    def fixture(self):
        plan = capture('web_xhtml')
        grant = {'vid': plan['owner'], 'deviceId': 'synthetic-device'}
        plan['device_sha256'] = digest(grant['deviceId'])
        sample = dict(point=dict(chapter_uid=plan['chapter_uid'], chapter_idx=plan['chapter_idx']),
                      version=plan['book_version'], source=plan['raw_sha256'])
        plan['baseline_sha256'] = digest(sample)
        bundle = {'plan': plan, 'evidence': {'synthetic': True}}
        store = Mock(); token = object(); store.read.return_value = (bundle, token)
        saved = {'vid': plan['owner'], 'cookies': {'wr_vid': plan['owner'], 'wr_skey': 'synthetic'}}
        session = Mock(); session.load.side_effect = lambda: deepcopy(saved)
        native = Mock(); native.load.side_effect = lambda _owner: deepcopy(grant)
        shelf = {'books': [{'bookId': plan['book_id'], 'title': 'Synthetic'}], 'archive': []}
        web = Mock(); web.book_id = plan['book_id']; web.chapter = plan['chapter_uid']; web.shards = {}
        web.inspect.return_value = {'cloud_position_stable': True, 'catalog_stable': True}
        web.request.return_value = shelf
        api = Mock(); api.request.return_value = shelf
        stats = Mock(); stats.request.return_value = {}
        stat = {'baseTime': 1, 'readTimes': {'1': 5}, 'totalReadTime': 5, 'readDays': 1}
        return locals()

    def execute(self, f, *, now=None, preview=False):
        now = f['plan']['not_before'] if now is None else now
        with patch.object(task, 'validate_evidence'), patch.object(task, 'xhtml_snapshot', return_value=f['sample']), \
             patch.object(task, 'statistics_projection', return_value=f['stat']), \
             patch.object(task, 'save_refreshed_web_session'):
            return task.run(f['store'], f['session'], f['native'], preview=preview, clock=lambda: now,
                            sleep=lambda _: None, web_factory=lambda _book: f['web'],
                            api_factory=lambda _grant, _book: f['api'], statistics_factory=lambda: f['stats'])

    def test_offline_and_before_boundary_do_not_load_credentials(self):
        with patch.object(task, 'capture_store') as store, redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]), 0)
            store.assert_not_called()
            self.assertFalse(json.loads(output.getvalue())['dispatch_capability'])
        f = self.fixture(); result = self.execute(f, now=f['plan']['not_before']-1)
        self.assertEqual(result['result'], 'NOT_YET_HISTORICAL')
        f['session'].load.assert_not_called(); f['native'].load.assert_not_called()

    def test_preview_and_cross_day_are_distinct_read_only_results(self):
        for preview in (False, True):
            f = self.fixture(); now = f['plan']['ended_at']+1 if preview else f['plan']['not_before']
            result = self.execute(f, now=now, preview=preview)
            self.assertEqual(result['result'], 'SAME_DAY_PREVIEW_VERIFIED' if preview else 'CROSS_DAY_READONLY_VERIFIED')
            self.assertFalse(result['captured_web_shelf_comparable'])
            self.assertFalse(result['dispatch_capability'])
            self.assertFalse(result['historical_accounting_verified'])
            self.assertEqual(result['account_data_posts'], 0)
            self.assertEqual(f['api'].request.call_count, 2)
            self.assertTrue(all(call.kwargs.get('body') is None for call in f['api'].request.call_args_list))

    def test_changes_to_capture_source_shelf_statistics_or_session_stop(self):
        for change in ('baseline', 'source', 'shelf', 'statistics', 'session', 'record'):
            f = self.fixture()
            if change == 'baseline': f['sample']['source'] = '0'*64
            elif change == 'source': f['web'].inspect.return_value = {'cloud_position_stable': False, 'catalog_stable': True}
            elif change == 'shelf':
                other = deepcopy(f['shelf']); other['books'][0]['secret'] = 1
                f['web'].request.side_effect = [f['shelf'], other]
            elif change == 'statistics':
                pass
            elif change == 'session':
                f['native'].load.side_effect = [deepcopy(f['grant']), dict(f['grant'], deviceId='changed')]
            else: f['store'].read.side_effect = [(f['bundle'], f['token']), (None, None)]
            if change == 'statistics':
                changed = dict(f['stat'], totalReadTime=6)
                with patch.object(task, 'validate_evidence'), patch.object(task, 'xhtml_snapshot', return_value=f['sample']), \
                     patch.object(task, 'statistics_projection', side_effect=[f['stat'], changed]), \
                     patch.object(task, 'save_refreshed_web_session'):
                    result = task.run(f['store'], f['session'], f['native'], clock=lambda:f['plan']['not_before'], sleep=lambda _:None,
                                      web_factory=lambda _book:f['web'], api_factory=lambda *_:f['api'], statistics_factory=lambda:f['stats'])
            else:
                result = self.execute(f)
            with self.subTest(change=change):
                self.assertEqual(result['result'], 'UNVERIFIED')
                self.assertFalse(result['dispatch_capability'])

    def test_same_day_preview_never_runs_after_boundary(self):
        f = self.fixture(); result = self.execute(f, preview=True)
        self.assertEqual(result['reason'], 'fresh_capture/not_same_day')
        f['session'].load.assert_not_called()

    def test_native_server_clock_is_validated_without_posting(self):
        api = task.TimedNative({'vid': '900000'}, '900001', clock=lambda: 1000)
        for value, accepted in ((1000, True), (940, True), (1060, True),
                                (939, False), (1061, False), (True, False), (None, False)):
            with self.subTest(timestamp=value), patch.object(task.Native, 'request', return_value={'timestamp': value}):
                if accepted:
                    api.request('native_capture_progress', 'unused', credentials={'vid':'900000'})
                else:
                    with self.assertRaisesRegex(ValueError, 'fresh_capture/server_clock'):
                        api.request('native_capture_progress', 'unused', credentials={'vid':'900000'})


if __name__ == '__main__':
    unittest.main()
