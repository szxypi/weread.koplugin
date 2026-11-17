"""Read-only native cross-day fixture and natural-date boundaries."""
from contextlib import ExitStack, redirect_stdout
from copy import deepcopy
import io
import json
import unittest
from unittest.mock import Mock, patch

from test_cloud_group_nonempty_contract import TARGET, source
from test_native_time_capture import capture
from txt_full_summary import digest
import verify_native_time_cross_day as task


class NativeCrossDayTests(unittest.TestCase):
    def test_default_is_offline_and_cannot_claim_or_dispatch(self):
        with patch.object(task, 'SessionStore') as sessions, patch.object(task, 'NativeCaptureStore') as captures, redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]), 0)
        sessions.assert_not_called()
        captures.assert_not_called()
        report = json.loads(out.getvalue())
        self.assertFalse(report['dispatch_capability'])
        self.assertFalse(report['historical_accounting_verified'])

    def test_remove_only_one_unassigned_fixture(self):
        value = source()
        value['archive'][0]['bookIds'].remove(TARGET)
        original = deepcopy(value)
        filtered = task.without_fixture(value, TARGET)
        self.assertEqual(value, original)
        self.assertEqual(filtered['books'], [value['books'][0]])
        self.assertEqual(filtered['archive'], value['archive'])
        self.assertEqual(filtered['albums'], value['albums'])
        cases = []
        missing = deepcopy(value); missing['books'].pop(); cases.append(missing)
        duplicate = deepcopy(value); duplicate['books'].append(deepcopy(duplicate['books'][-1])); cases.append(duplicate)
        grouped = deepcopy(value); grouped['archive'][0]['bookIds'].append(TARGET); cases.append(grouped)
        album = deepcopy(value); album['archive'][0]['albumIds'].append(TARGET); cases.append(album)
        for item in cases:
            with self.subTest(item=item), self.assertRaises(ValueError):
                task.without_fixture(item, TARGET)

    def test_group_requires_verified_unchanged_state_on_both_channels(self):
        result = dict(phase='create_claimed', dispatched=True, native_fixture_present=True, web_fixture_present=True,
                      native_group_present=False, web_group_present=False)
        original = dict(native_original_state_unchanged=True, web_original_state_unchanged=True, old_group_absent=True)
        task.check_group(result, original)
        for key in result:
            changed = deepcopy(result); changed[key] = None
            with self.subTest(key=key), self.assertRaises(ValueError): task.check_group(changed, original)
        for key in original:
            changed = deepcopy(original); changed[key] = False
            with self.subTest(key=key), self.assertRaises(ValueError): task.check_group(result, changed)

    def test_capture_requires_real_boundary_owner_device_and_sealed_source(self):
        plan = capture('web_xhtml')
        grant = {'vid':plan['owner'], 'deviceId':'synthetic-device'}
        saved = {'vid':plan['owner']}
        plan['device_sha256'] = digest(grant['deviceId'])
        task.check_capture(plan, saved, grant, plan['not_before'])
        with self.assertRaises(ValueError): task.check_capture(plan, saved, grant, plan['not_before'] - 1)
        for key, value in (('vid', '1'), ('deviceId', 'different')):
            changed = dict(grant); changed[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): task.check_capture(plan, saved, changed, plan['not_before'])
        wrong_format = capture('web_txt'); wrong_format['device_sha256'] = digest(grant['deviceId'])
        with self.assertRaisesRegex(ValueError, 'native_cross_day/format'): task.check_capture(wrong_format, saved, grant, wrong_format['not_before'])
        damaged = deepcopy(plan); damaged['seconds'] = 5
        with self.assertRaises(ValueError): task.check_capture(damaged, saved, grant, plan['not_before'])



    def test_fixture_projection_follows_the_capture_baseline_and_still_requires_one_fixture(self):
        shelf=source();shelf['archive'][0]['bookIds'].remove(TARGET)
        for includes in (False,True):
            api=task.FilteredNative({'vid':'900000'},'900001',TARGET,1,clock=lambda:2,baseline_includes_fixture=includes)
            with patch.object(task.Native,'request',return_value=shelf):
                value=api.request('native_capture_shelf','unused',credentials={'vid':'900000'})
            self.assertEqual(len(value['books']),2 if includes else 1)
            absent=deepcopy(shelf);absent['books'].pop()
            with patch.object(task.Native,'request',return_value=absent),self.assertRaises(ValueError):
                api.request('native_capture_shelf','unused',credentials={'vid':'900000'})
        with self.assertRaises(ValueError):task.FilteredNative({},'1',TARGET,1,baseline_includes_fixture='yes')

    def test_two_fresh_reads_are_required_and_changes_stop_preflight(self):
        plan = capture('web_xhtml')
        grant = {'vid':plan['owner'], 'deviceId':'synthetic-device'}
        plan['device_sha256'] = digest(grant['deviceId'])
        saved = {'vid':plan['owner']}
        sample = dict(point=dict(chapter_uid=int(plan['chapter_uid']), chapter_idx=plan['chapter_idx']),
                      version=plan['book_version'], source=plan['raw_sha256'])
        plan['baseline_sha256'] = digest(sample)
        state, token = {'plan':plan}, object()
        upload = {'target':TARGET, 'plan':{'owner':plan['owner']}}
        group, old = {'target':TARGET}, {'phase':'closed_unverified'}
        group_result = dict(phase='create_claimed', dispatched=True, native_fixture_present=True,
                            web_fixture_present=True, native_group_present=False, web_group_present=False)
        original_result = dict(native_original_state_unchanged=True, web_original_state_unchanged=True, old_group_absent=True)
        stable_stat = dict(baseTime=1, readTimes={'1':5}, totalReadTime=5, readDays=1)

        def run_case(*, samples=None, statistics=None, changed_store=False, now=None, includes_fixture=False):
            clock = plan['not_before'] if now is None else now
            month_count = len({task.period('monthly', plan['start_time'])[0], task.period('monthly', clock)[0]})
            store = Mock(); store.read.side_effect = [(state, token), (None, None)] if changed_store else None
            if not changed_store: store.read.return_value = (state, token)
            uploads, groups, olds, receipt = Mock(), Mock(), Mock(), Mock()
            groups.read.return_value = (group, 'g'); olds.read.return_value = (old, 'o')
            web = Mock(); web.book_id = plan['book_id']; web.chapter = plan['chapter_uid']
            api, stats = Mock(), Mock()
            api_factory = Mock(return_value=api)
            with ExitStack() as stack:
                for name, value in [('UploadJournal',uploads), ('GroupJournal',groups), ('OldJournal',olds),
                                    ('TargetReceipt',receipt), ('ScopedNative',Mock()), ('Guard',Mock()), ('Binding',Mock()), ('NonemptyBinding',Mock())]:
                    stack.enter_context(patch.object(task, name, return_value=value))
                stack.enter_context(patch.object(task, 'binding', return_value=(upload, 'u')))
                stack.enter_context(patch.object(task, 'inspect', return_value=group_result))
                stack.enter_context(patch.object(task, 'inspect_original', return_value=original_result))
                snapshots = stack.enter_context(patch.object(task, 'xhtml_snapshot', side_effect=samples or [sample, sample]))
                stack.enter_context(patch.object(task, 'project_statistics', side_effect=statistics or [stable_stat] * (2 * month_count)))
                result = task.run(saved, grant, store, lambda:True, web, api_factory=api_factory,
                                  statistics_factory=lambda:stats, clock=lambda:clock, sleep=lambda _:None, baseline_includes_fixture=includes_fixture)
                self.assertEqual(api_factory.call_args.args[-1], includes_fixture)
                self.assertEqual(snapshots.call_count, 2)
                self.assertEqual(stats.request.call_count, 2 * month_count)
                self.assertEqual(web.inspect.call_count, 1)
                return result
        result = run_case()
        self.assertEqual(result['result'], 'CROSS_DAY_READONLY_VERIFIED')
        self.assertFalse(result['historical_accounting_verified'])
        self.assertEqual(run_case(now=plan['not_before'] + 40*86400)['observed_months'], 2)
        self.assertEqual(run_case(includes_fixture=True)['result'], 'CROSS_DAY_READONLY_VERIFIED')
        changed = deepcopy(sample); changed['point']['chapter_idx'] += 1
        with self.assertRaisesRegex(ValueError, 'native_cross_day/baseline'): run_case(samples=[sample, changed])
        changed_stat = deepcopy(stable_stat); changed_stat['totalReadTime'] += 1
        with self.assertRaisesRegex(ValueError, 'native_cross_day/statistics_changed'): run_case(statistics=[stable_stat, changed_stat])
        with self.assertRaisesRegex(ValueError, 'native_cross_day/state_changed'): run_case(changed_store=True)


if __name__ == '__main__': unittest.main()
