#!/usr/bin/env python3
"""Read-only cross-day inspection of the sealed native reading window.

The only permitted shelf adjustment is the separately journaled fixture. This
script cannot dispatch time, claim a send, or change any account data.
"""
import argparse
from copy import deepcopy
import json
import re
import resource
import time

from cloud_group_binding import Binding
from cloud_group_contract import project
from cloud_group_fixture import Journal as UploadJournal, binding
from cloud_group_journal import Journal as OldJournal
from cloud_group_nonempty_binding import Binding as NonemptyBinding
from cloud_group_nonempty_inspect import inspect, inspect_original
from cloud_group_nonempty_journal import Journal as GroupJournal
from cloud_group_nonempty_transport import ScopedNative
from cloud_group_old_guard import Guard
from native_time_capture import NativeCaptureStore, validate
from native_time_bundle_gate import day
from readtime_upload_model import integer
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from synthetic_format_trial import TargetReceipt
from txt_full_summary import digest
from verify_cloud_group_trial import no_other_pending
from verify_eink_login import BASE
from verify_native_statistics import StatisticsProbe, period, project as project_statistics
from verify_native_time_capture import XhtmlSource, xhtml_snapshot
from verify_native_txt_position import Native
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE as WEB
from web_shelf_contract import identity


def without_fixture(source, target):
    """Remove exactly one validated fixture book, never a group membership."""
    value = project(source)
    if value['members'].count(target) != 1:
        raise ValueError('native_cross_day/fixture')
    for row in value['groups'].values():
        if target in row['bookIds'] or target in row.get('albumIds', []):
            raise ValueError('native_cross_day/fixture_group')
    result = deepcopy(source)
    result['books'] = [row for row in result['books'] if identity(row['bookId']) != target]
    project(result)
    return result


def check_group(result, original):
    if (not isinstance(result,dict) or not isinstance(original,dict)
            or result.get('phase') != 'create_claimed' or result.get('dispatched') is not True
            or any(result.get(k) is not True for k in ('native_fixture_present', 'web_fixture_present'))
            or any(result.get(k) is not False for k in ('native_group_present', 'web_group_present'))
            or any(original.get(k) is not True for k in
                   ('native_original_state_unchanged', 'web_original_state_unchanged', 'old_group_absent'))):
        raise ValueError('native_cross_day/group')


def check_group_fresh(result, original):
    """Check the old trial's identity and absence without claiming its old shelf is unchanged."""
    if (not isinstance(result,dict) or not isinstance(original,dict)
            or result.get('phase') != 'create_claimed' or result.get('dispatched') is not True
            or any(result.get(k) is not True for k in ('native_fixture_present', 'web_fixture_present'))
            or any(result.get(k) is not False for k in ('native_group_present', 'web_group_present'))
            or original.get('old_group_absent') is not True
            or any(type(original.get(k)) is not bool for k in
                   ('native_original_state_unchanged', 'web_original_state_unchanged'))):
        raise ValueError('native_cross_day/group')


def check_capture(plan, saved, grant, now):
    validate(plan)
    if plan['format'] != 'web_xhtml':
        raise ValueError('native_cross_day/format')
    if now < plan['not_before']:
        raise ValueError('native_cross_day/not_ready')
    if saved['vid'] != grant['vid'] or saved['vid'] != plan['owner'] or digest(grant['deviceId']) != plan['device_sha256']:
        raise ValueError('native_cross_day/owner_device')


class FilteredNative(Native):
    def __init__(self, credentials, book, target, not_before, clock=time.time, baseline_includes_fixture=False):
        if type(baseline_includes_fixture) is not bool:raise ValueError('native_cross_day/fixture_mode')
        super().__init__(credentials, book)
        self.target, self.not_before, self.clock = target, not_before, clock
        self.baseline_includes_fixture = baseline_includes_fixture

    def request(self, stage, url, body=None, credentials=None, timeout=15):
        value = super().request(stage, url, body, credentials, timeout)
        if stage == 'native_capture_progress':
            stamp = value.get('timestamp')
            if (not integer(stamp, 1, 4102444800) or stamp < self.not_before
                    or self.clock() < self.not_before or abs(stamp-self.clock()) > 60):
                raise ValueError('native_cross_day/server_clock')
        if stage == 'native_capture_shelf':
            original = without_fixture(value, self.target)
            return value if self.baseline_includes_fixture else original
        return value


def run(saved, grant, store, current, web, api_factory=FilteredNative,
        statistics_factory=StatisticsProbe, clock=time.time, sleep=time.sleep, baseline_includes_fixture=False,
        private_evidence=False, fresh_shelf=False):
    if (type(baseline_includes_fixture) is not bool or type(private_evidence) is not bool
            or type(fresh_shelf) is not bool or fresh_shelf and not baseline_includes_fixture):
        raise ValueError('native_cross_day/fixture_mode')
    if private_evidence and not baseline_includes_fixture:raise ValueError('native_cross_day/fixture_mode')
    state, token = store.read()
    if not state or current() is not True:
        raise ValueError('native_cross_day/capture')
    plan = state['plan']
    check_capture(plan, saved, grant, clock())
    uploads, groups, old = UploadJournal(), GroupJournal(), OldJournal()
    receipt = TargetReceipt('epub', scope='group-fixture')
    fixture = lambda: binding(uploads, receipt.backend)
    upload, upload_token = fixture()
    group, group_token = groups.read()
    old_state, old_token = old.read()
    if not group or group['target'] != upload['target'] or upload['plan']['owner'] != plan['owner']:
        raise ValueError('native_cross_day/fixture_binding')
    native = ScopedNative(groups, fixture, grant, current, no_other_pending, lambda: True)
    def read_pair():
        web.verify_account()
        return {'native': native.shelf(), 'web': web.request('shelf', WEB+'/web/shelf/sync')}
    guard = Guard(old, Binding(), grant, current, read_pair)
    readonly = NonemptyBinding()
    fresh_projection,prior_matches = None,None
    def check_groups():
        nonlocal fresh_projection,prior_matches
        result = inspect(groups, fixture, grant, current, read_pair, readonly)
        original = inspect_original(old, groups, fixture, grant, current, read_pair, guard.check, readonly)
        if not fresh_shelf:
            check_group(result, original)
            return
        check_group_fresh(result, original)
        observations=[]
        for _ in range(2):
            pair=read_pair()
            if not isinstance(pair,dict) or set(pair)!={'native','web'}:raise ValueError('native_cross_day/shelf')
            # Both channels must retain precisely one ungrouped fixture; never
            # remove it or infer that the earlier unobserved operation failed.
            for key in ('native','web'):without_fixture(pair[key],upload['target'])
            observations.append(tuple(digest(project(pair[key])) for key in ('native','web')))
        matches=(original['native_original_state_unchanged'],original['web_original_state_unchanged'])
        if observations[0]!=observations[1] or fresh_projection is not None and observations[1]!=fresh_projection \
                or prior_matches is not None and matches!=prior_matches:
            raise ValueError('native_cross_day/shelf_changed')
        fresh_projection,prior_matches=observations[1],matches
    check_groups()
    web.verify_account()
    web.prepare()
    if web.book_id != plan['book_id'] or web.chapter != plan['chapter_uid']:
        raise ValueError('native_cross_day/source')
    api = api_factory(grant, plan['book_id'], upload['target'], plan['not_before'], clock, baseline_includes_fixture)
    stats = statistics_factory()
    started_at=int(clock());previous_at=started_at;current_month = period('monthly', started_at)[0]
    months = sorted({period('monthly', plan['start_time'])[0], current_month})
    observations = [];catalog_pairs=[]
    for index in range(2):
        if index:
            sleep(2)
            checked=web.inspect(web.book_id)
            if (not isinstance(checked,dict) or checked.get('cloud_position_stable') is not True
                    or checked.get('catalog_stable') is not True or web.book_id!=plan['book_id']
                    or web.chapter!=plan['chapter_uid']):
                raise ValueError('native_cross_day/second_read_changed')
        observed_at=int(clock())
        if observed_at<plan['not_before'] or observed_at<previous_at or day(observed_at)!=day(started_at):
            raise ValueError('native_cross_day/clock')
        previous_at=observed_at
        sample = xhtml_snapshot(web, api, grant)
        if private_evidence:catalog_pairs.append(deepcopy(web._time_catalog_pair))
        checks = {'complete_baseline_matches': digest(sample) == plan['baseline_sha256'],
                  'version_matches': sample['version'] == plan['book_version'],
                  'source_matches': sample['source'] == plan['raw_sha256'],
                  'chapter_matches': identity(sample['point']['chapter_uid']) == plan['chapter_uid'],
                  'chapter_index_matches': sample['point']['chapter_idx'] == plan['chapter_idx']}
        if not all(checks.values()):
            error = ValueError('native_cross_day/baseline')
            error.checks = checks
            raise error
        observed_at=int(clock())
        if observed_at<previous_at or day(observed_at)!=day(started_at):
            raise ValueError('native_cross_day/clock')
        previous_at=observed_at
        if period('monthly', observed_at)[0] != current_month:
            raise ValueError('native_cross_day/month_changed')
        month_stats = {}
        for month in months:
            raw = stats.request('statistics_monthly', BASE+'/readdata/detail?mode=monthly&baseTime='+str(month), credentials=grant)
            stat = project_statistics(raw, 'monthly', month)
            month_stats[str(month)] = {k: stat[k] for k in ('baseTime', 'readTimes', 'totalReadTime', 'readDays')}
        observations.append(month_stats)
    if observations[0] != observations[1]:
        raise ValueError('native_cross_day/statistics_changed')
    check_groups()
    web.verify_account()
    if (current() is not True or store.read() != (state, token) or fixture() != (upload, upload_token)
            or groups.read() != (group, group_token) or old.read() != (old_state, old_token)):
        raise ValueError('native_cross_day/state_changed')
    completed_at=int(clock())
    if (completed_at<plan['not_before'] or completed_at<previous_at or day(completed_at)!=day(started_at)
            or period('monthly',completed_at)[0]!=current_month):
        raise ValueError('native_cross_day/clock')
    report={'result': 'CROSS_DAY_READONLY_VERIFIED', 'seconds': plan['seconds'],
            'exact_capture_and_fixture_bound': True, 'fixture_in_captured_baseline': baseline_includes_fixture,
            'both_positions_source_counts_and_original_shelf_exact': True,
            'two_statistics_reads_stable': True, 'observed_months': len(months), 'server_clock_after_boundary': True,
            'completed_at': completed_at,
            'account_data_posts': 0, 'authentication_posts': 0,
            'historical_accounting_verified': False, 'dispatch_capability': False}
    if fresh_shelf:
        # This is a new read-only baseline, not evidence that the older group
        # trial's shelf was restored and not an authorization to dispatch.
        report.pop('both_positions_source_counts_and_original_shelf_exact')
        report.update(result='CAPTURE_FRESH_SHELF_READONLY_VERIFIED',
            captured_native_shelf_positions_source_counts_exact=True,
            fresh_native_and_web_shelf_stable=True,
            previous_native_group_baseline_matches=prior_matches[0],
            previous_web_group_baseline_matches=prior_matches[1])
    if private_evidence:
        if fresh_shelf:
            from native_time_bundle_evidence import FreshShelfEvidence
            return FreshShelfEvidence(state,grant,report,sample,observations[-1],catalog_pairs,fresh_projection)
        from native_time_bundle_evidence import PreflightEvidence
        return PreflightEvidence(state,grant,report,sample,observations[-1],catalog_pairs)
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--bundle', action='store_true')
    parser.add_argument('--fresh-shelf', action='store_true', help='read-only bundle audit with a new stable shelf baseline')
    args = parser.parse_args(argv)
    if args.bundle and not args.saved_session:parser.error('bundle inspection requires saved session')
    if args.fresh_shelf and not (args.saved_session and args.bundle):parser.error('fresh shelf inspection requires a saved bundle')
    result = {'result':'OFFLINE_ONLY', 'account_data_posts':0, 'authentication_posts':0,
              'historical_accounting_verified':False, 'dispatch_capability':False}
    saved = grant = web = None
    try:
        if args.saved_session:
            resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
            session, native_session = SessionStore(), NativeSessionStore()
            saved = session.load()
            grant = native_session.load(saved['vid'])
            web = XhtmlSource()
            web.vid = saved['vid']
            for key, value in saved['cookies'].items():
                web.set_cookie(key, value)
            current = lambda: session.load() == saved and native_session.load(saved['vid']) == grant
            if args.bundle:
                from native_time_capture_bundle import CaptureBundleStore
                capture=CaptureBundleStore()
            else:capture=NativeCaptureStore()
            result = run(saved, grant, capture, current, web, baseline_includes_fixture=args.bundle,fresh_shelf=args.fresh_shelf)
            result['web_rotation_saved'] = save_refreshed_web_session(session, saved, web)
    except (Exception, KeyboardInterrupt) as error:
        result['result'] = 'NOT_READY' if isinstance(error, ValueError) and str(error) == 'native_cross_day/not_ready' else 'UNVERIFIED'
        if isinstance(error, ValueError) and re.fullmatch(r'native_cross_day/[a-z_]+', str(error)):
            result['reason'] = str(error)
            if getattr(error, 'checks', None):
                result['baseline_checks'] = error.checks
    finally:
        if web:
            result['web_stages'] = [{k: row[k] for k in ('stage', 'status') if k in row} for row in web.report['stages']]
            web.shards.clear()
            web.close()
        for value in (saved, grant):
            if value:
                value.clear()
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return int(result['result'] == 'UNVERIFIED')


if __name__ == '__main__':
    raise SystemExit(main())
