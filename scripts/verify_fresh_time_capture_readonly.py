#!/usr/bin/env python3
"""Read-only checks for the independent ordinary-book time capture.

No dispatch, token acquisition, clock override, or legacy-trial mutation.
The Web shelf is checked for stability now; its capture-time state was not saved.
"""
import argparse
from copy import deepcopy
import json
import re
import resource
import time

from cloud_group_contract import project as shelf_projection
from native_time_bundle_gate import day
from native_time_capture_evidence import validate_evidence
from native_time_capture_fresh_bundle import store as capture_store
from readtime_upload_model import integer
from secure_native_session import NativeSessionStore
from secure_weread_session import MacKeychain, SessionStore
from txt_full_summary import digest
from verify_eink_login import BASE
from verify_native_statistics import StatisticsProbe, period, project as statistics_projection
from verify_native_time_capture import XhtmlSource, xhtml_snapshot
from verify_native_txt_position import Native
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE as WEB


class BoundSource(XhtmlSource):
    def __init__(self, target):
        super().__init__()
        self.target = target

    def select_shelf_book(self):
        if not self.authenticated:
            raise ValueError('fresh_capture/login')
        shelf = self.request('shelf', WEB + '/web/shelf/sync')
        projected = shelf_projection(shelf)
        if projected['members'].count(self.target) != 1:
            raise ValueError('fresh_capture/shelf')
        self.book_id = self.target
        self.report['shelf_book_count'] = len(projected['members'])
        return self.target


class TimedNative(Native):
    def __init__(self, grant, book, clock=time.time):
        super().__init__(grant, book)
        self.clock = clock

    def request(self, stage, url, body=None, credentials=None, timeout=15):
        value = super().request(stage, url, body, credentials, timeout)
        if stage == 'native_capture_progress':
            stamp = value.get('timestamp')
            if not integer(stamp, 1, 4102444800) or abs(stamp-self.clock()) > 60:
                raise ValueError('fresh_capture/server_clock')
        return value


def run(store, session, native_session, *, preview=False, clock=time.time, sleep=time.sleep,
        web_factory=BoundSource, api_factory=TimedNative, statistics_factory=StatisticsProbe, private_evidence=False):
    result = dict(result='UNVERIFIED', account_data_posts=0, authentication_posts=0,
                  historical_accounting_verified=False, dispatch_capability=False,
                  captured_web_shelf_comparable=False)
    saved = grant = web = None
    try:
        if type(preview) is not bool or type(private_evidence) is not bool or preview and private_evidence:
            raise ValueError('fresh_capture/mode')
        if isinstance(getattr(store, 'backend', None), MacKeychain) and (
                clock is not time.time or sleep is not time.sleep or web_factory is not BoundSource
                or api_factory is not TimedNative or statistics_factory is not StatisticsProbe
                or type(session) is not SessionStore or type(native_session) is not NativeSessionStore):
            raise ValueError('fresh_capture/override')
        bundle, receipt = store.read()
        if not bundle or receipt is None:
            raise ValueError('fresh_capture/missing')
        plan = bundle['plan']
        validate_evidence(plan, bundle['evidence'])
        started = int(clock())
        if started < plan['ended_at']:
            raise ValueError('fresh_capture/clock')
        if not preview and started < plan['not_before']:
            result['result'] = 'NOT_YET_HISTORICAL'
            return result
        if preview and started >= plan['not_before']:
            raise ValueError('fresh_capture/not_same_day')
        saved = session.load()
        grant = native_session.load(saved['vid'])
        if (plan['format'] != 'web_xhtml' or saved['vid'] != grant['vid'] or saved['vid'] != plan['owner']
                or digest(grant['deviceId']) != plan['device_sha256']):
            raise ValueError('fresh_capture/owner_device')
        def current():
            return session.load() == saved and native_session.load(saved['vid']) == grant
        if not current():
            raise ValueError('fresh_capture/session')
        web = web_factory(plan['book_id'])
        web.vid = saved['vid']
        for key, value in saved['cookies'].items():
            web.set_cookie(key, value)
        web.verify_account()
        web.prepare()
        if web.book_id != plan['book_id'] or web.chapter != plan['chapter_uid']:
            raise ValueError('fresh_capture/source')
        api = api_factory(grant, plan['book_id'])
        stats = statistics_factory()
        months = sorted({period('monthly', plan['start_time'])[0], period('monthly', started)[0]})
        observations = []
        catalog_pairs = []
        component_pairs = []
        last = started
        for index in range(2):
            if index:
                sleep(2)
                checked = web.inspect(web.book_id)
                if (not isinstance(checked, dict) or checked.get('cloud_position_stable') is not True
                        or checked.get('catalog_stable') is not True or web.book_id != plan['book_id']
                        or web.chapter != plan['chapter_uid']):
                    raise ValueError('fresh_capture/source_changed')
            now = int(clock())
            if now < last or day(now) != day(started) or period('monthly', now)[0] != period('monthly', started)[0]:
                raise ValueError('fresh_capture/clock')
            if (now < plan['not_before']) != preview:
                raise ValueError('fresh_capture/boundary')
            last = now
            sample = xhtml_snapshot(web, api, grant)
            if (digest(sample) != plan['baseline_sha256'] or sample['version'] != plan['book_version']
                    or sample['source'] != plan['raw_sha256']
                    or str(sample['point']['chapter_uid']) != plan['chapter_uid']
                    or sample['point']['chapter_idx'] != plan['chapter_idx']):
                raise ValueError('fresh_capture/baseline')
            native_shelf = api.request('native_capture_shelf', BASE + '/shelf/sync', credentials=grant)
            web_shelf = web.request('shelf', WEB + '/web/shelf/sync')
            shelves = [shelf_projection(value) for value in (native_shelf, web_shelf)]
            if any(shelf['members'].count(plan['book_id']) != 1 for shelf in shelves):
                raise ValueError('fresh_capture/shelf')
            if private_evidence:
                from native_time_shelf_components import make
                catalog_pairs.append(deepcopy(web._time_catalog_pair))
                components=tuple(make(value) for value in shelves)
                component_pairs.append(components if all(value is not None for value in components) else None)
            months_read = {}
            for month in months:
                raw = stats.request('statistics_monthly', BASE + '/readdata/detail?mode=monthly&baseTime=' + str(month), credentials=grant)
                value = statistics_projection(raw, 'monthly', month)
                months_read[str(month)] = {key: value[key] for key in ('baseTime', 'readTimes', 'totalReadTime', 'readDays')}
            observations.append((tuple(digest(value) for value in shelves), months_read))
            if not current():
                raise ValueError('fresh_capture/session')
        if observations[0] != observations[1]:
            raise ValueError('fresh_capture/observations_changed')
        completed = int(clock())
        if (completed < last or day(completed) != day(started) or (completed < plan['not_before']) != preview
                or period('monthly', completed)[0] != period('monthly', started)[0]):
            raise ValueError('fresh_capture/clock')
        web.verify_account()
        if not current() or store.read() != (bundle, receipt):
            raise ValueError('fresh_capture/state_changed')
        final_time = int(clock())
        if (final_time < completed or day(final_time) != day(started)
                or (final_time < plan['not_before']) != preview
                or period('monthly', final_time)[0] != period('monthly', started)[0]):
            raise ValueError('fresh_capture/clock')
        save_refreshed_web_session(session, saved, web)
        result.update(result='SAME_DAY_PREVIEW_VERIFIED' if preview else 'CROSS_DAY_READONLY_VERIFIED',
                      seconds=plan['seconds'], captured_native_baseline_matches=True,
                      both_current_shelves_stable=True, two_statistics_reads_stable=True,
                      observed_months=len(months), saved_capture_unchanged=True)
        if private_evidence:
            from native_time_bundle_evidence import IndependentCaptureEvidence
            if component_pairs[0]!=component_pairs[1]:raise ValueError('fresh_capture/observations_changed')
            report=dict(result,completed_at=final_time)
            return IndependentCaptureEvidence(bundle,grant,report,sample,observations[0][1],catalog_pairs,
                                              observations[0][0],components=component_pairs[0])
    except (Exception, KeyboardInterrupt) as error:
        result['result'] = 'UNVERIFIED'
        if isinstance(error, ValueError) and re.fullmatch(r'fresh_capture/[a-z_]+', str(error)):
            result['reason'] = str(error)
    finally:
        if web:
            web.shards.clear()
            if hasattr(web,'_time_catalog_pair'):web._time_catalog_pair.clear()
            web.close()
        for value in (saved, grant):
            if isinstance(value, dict):
                value.clear()
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-capture', action='store_true')
    parser.add_argument('--same-day-preview', action='store_true')
    args = parser.parse_args(argv)
    if args.same_day_preview and not args.saved_capture:
        parser.error('preview requires the saved capture')
    if not args.saved_capture:
        result = dict(result='OFFLINE_ONLY', account_data_posts=0, authentication_posts=0,
                      historical_accounting_verified=False, dispatch_capability=False)
    else:
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        result = run(capture_store(), SessionStore(), NativeSessionStore(), preview=args.same_day_preview)
    print(json.dumps(result, ensure_ascii=False))
    return int(result['result'] == 'UNVERIFIED')


if __name__ == '__main__':
    raise SystemExit(main())
