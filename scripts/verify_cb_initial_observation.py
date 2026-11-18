#!/usr/bin/env python3
"""Read-only inventory of imported-book initial cloud states.

No book is selected for a write and no previously consumed experiment is
read, changed or replayed. Private responses remain in process memory.
"""
import argparse
import json
import resource
from urllib.parse import urlencode

from cb_cloud_position import observed
from cloud_group_contract import project
from secure_native_session import NativeSessionStore
from secure_weread_session import COOKIE_NAMES, SessionStore
from verify_cb_cloud_position import Native
from verify_cb_progress import CbProgressProbe, cb_ids
from verify_eink_login import BASE as NATIVE
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE as WEB, WebSourceProbe


def summarize(samples):
    """Count only explicit, stable no-chapter observations on both channels."""
    result = dict(books_checked=0, both_no_chapter=0, mixed_no_chapter=0,
                  neither_no_chapter=0, native_zero_counts=0, native_counts_nonzero=0, native_counts_incomplete=0)
    for sample in samples:
        if set(sample) != {'native', 'web'}:
            raise ValueError('initial_observation/channels')
        native, web = sample['native'], sample['web']
        if any(not isinstance(pair, list) or len(pair) != 2 or pair[0] != pair[1]
               for pair in (native, web)):
            raise ValueError('initial_observation/changed')
        n = native[0]['state']['kind'] == 'no_chapter'
        w = web[0]['state']['kind'] == 'no_chapter'
        result['books_checked'] += 1
        result['both_no_chapter' if n and w else 'mixed_no_chapter' if n or w else 'neither_no_chapter'] += 1
        if n and w:
            counters = native[0]['counters']
            values = [counters[k] for k in ('readingTime', 'recordReadingTime', 'ttsTime')]
            if not all(v['present'] and type(v['value']) is int and v['value'] >= 0 for v in values):
                result['native_counts_incomplete'] += 1
            elif all(v['value'] == 0 for v in values):
                result['native_zero_counts'] += 1
            else:
                result['native_counts_nonzero'] += 1
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    args = parser.parse_args(argv)
    report = dict(result='OFFLINE_ONLY', account_data_writes=0, authentication_posts=0,
                  private_responses_saved=False, grants_write_authority=False)
    if not args.saved_session:
        print(json.dumps(report)); return 0
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    saved = grant = web = probe = None
    try:
        store = SessionStore(); saved = store.load(); grant = NativeSessionStore().load(saved['vid'])
        api = Native(grant); web = WebSourceProbe(); web.vid = saved['vid']
        for key, value in saved['cookies'].items(): web.set_cookie(key, value)
        web.verify_account()
        ns = api.request('initial_shelf', NATIVE + '/shelf/sync', credentials=grant)
        ws = web.request('shelf', WEB + '/web/shelf/sync')
        ids = cb_ids(ns)
        if cb_ids(ws) != ids: raise ValueError('initial_observation/shelf')
        api.allowed = set(ids)
        shelf_before = (project(ns), project(ws))
        cookies = {c.name: c.value for c in web.cookies if c.name in COOKIE_NAMES
                   and c.domain in ('.weread.qq.com', 'weread.qq.com') and c.path == '/'}
        samples = {identity: {'native': [], 'web': []} for identity in ids}
        for _ in range(2):
            probe = CbProgressProbe(cookies, ids)
            for identity in ids:
                native = api.request('initial_progress', NATIVE + '/book/getProgress?' + urlencode(dict(bookId=identity)), credentials=grant)
                remote = probe.fetch(identity)
                samples[identity]['native'].append(observed(native, identity, [], 'native'))
                samples[identity]['web'].append(observed(remote, identity, [], 'web'))
            probe.close(); probe = None
        counts = summarize(list(samples.values()))
        ns_after = api.request('initial_shelf_after', NATIVE + '/shelf/sync', credentials=grant)
        ws_after = web.request('shelf', WEB + '/web/shelf/sync')
        if (project(ns_after), project(ws_after)) != shelf_before: raise ValueError('initial_observation/shelf_changed')
        web.verify_account()
        report.update(counts, result='INITIAL_STATES_READ', shelf_projection_unchanged=True)
    except Exception:
        report.update(result='UNVERIFIED', reason='initial_observation_unavailable')
    finally:
        if probe: probe.close()
        if web:
            if web.authenticated and saved:
                try: report['web_session_refreshed'] = save_refreshed_web_session(store, saved, web)
                except Exception: report.update(result='UNVERIFIED', reason='initial_observation_session_unavailable')
            web.close()
        if grant: grant.clear()
        if saved: saved.clear()
    print(json.dumps(report, ensure_ascii=False)); return int(report['result'] != 'INITIAL_STATES_READ')


if __name__ == '__main__': raise SystemExit(main())
