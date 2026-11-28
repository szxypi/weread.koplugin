#!/usr/bin/env python3
"""Bounded read-only inventory for books with time but no first position.

Default is offline. Private identities, responses and credentials stay in memory;
no session renewal, account mutation, retry, or writable trial is performed.
"""
import argparse
import json
import re
import resource
import time
from urllib.parse import urlencode, urlsplit, parse_qs

from cloud_group_contract import project as shelf_projection
from native_initial_position import counts, no_chapter
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore, StoreError
from verify_eink_login import BASE as NATIVE_BASE, NativeProbe
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE as WEB_BASE, WebSourceProbe

MAX_BOOKS = 160


def numeric_books(shelf):
    rows = shelf.get('books') if isinstance(shelf, dict) else None
    if not isinstance(rows, list) or len(rows) > 5000:
        raise ValueError('inventory/shelf')
    seen, ids = set(), []
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError('inventory/shelf')
        raw = row.get('bookId')
        if type(raw) is int and 0 < raw <= 9007199254740991:
            ident = str(raw)
        elif isinstance(raw, str) and re.fullmatch(r'[1-9][0-9]{0,19}', raw):
            ident = raw
        else:
            continue
        if ident in seen:
            raise ValueError('inventory/duplicate')
        seen.add(ident); ids.append(ident)
    return ids


def classify(raw, ident):
    try:
        point = no_chapter(raw, ident)
    except (ValueError, TypeError, StoreError):
        return 'other_or_unverified', None
    try:
        values = counts(raw, ident)
    except (ValueError, TypeError):
        return 'missing_counts', None
    return ('nonzero' if any(values.values()) else 'zero'), (point, values)


class ScopedNative(NativeProbe):
    def __init__(self, grant, opener=None):
        super().__init__(opener); self.grant = grant; self.allowed = set(); self.used = {}

    def request(self, stage, url, body=None, credentials=None, timeout=15):
        parsed = urlsplit(url); query = parse_qs(parsed.query, keep_blank_values=True)
        shelf = parsed.path == '/shelf/sync' and not query and stage in ('shelf', 'shelf_after')
        progress = (parsed.path == '/book/getProgress' and set(query) == {'bookId'}
                    and len(query['bookId']) == 1 and query['bookId'][0] in self.allowed and stage == 'progress')
        key = (parsed.path, parsed.query)
        if (body is not None or credentials != self.grant or parsed.scheme != 'https'
                or parsed.netloc != 'i.weread.qq.com' or parsed.fragment or parsed.username
                or not (shelf or progress) or self.used.get(key, 0) >= 2):
            raise ValueError('inventory/scope')
        self.used[key] = self.used.get(key, 0) + 1
        return super().request(stage, url, credentials=credentials, timeout=timeout)


def inspect(api, web, grant, offset, limit, pause=time.sleep):
    before = api.request('shelf', NATIVE_BASE + '/shelf/sync', credentials=grant)
    ids = numeric_books(before)
    if not ids or offset >= len(ids):
        raise ValueError('inventory/range')
    selected = ids[offset:offset + limit]; api.allowed = set(selected)
    reference = shelf_projection(before)
    report = dict(numeric_books=len(ids), selected=len(selected), checked=0,
                  zero=0, nonzero=0, missing_counts=0, other_or_unverified=0,
                  candidate_dual_channel_stable=False, account_writes=0, authorization_posts=0)
    for index, ident in enumerate(selected, offset + 1):
        raw = api.request('progress', NATIVE_BASE + '/book/getProgress?' + urlencode({'bookId': ident}), credentials=grant)
        category, state = classify(raw, ident)
        report[category] += 1; report['checked'] += 1
        if category == 'nonzero':
            # Confirm both channels and the exact native counters before reporting
            # a candidate. Do not output its ID, counters or contents.
            pause(0.5)
            native_again = api.request('progress', NATIVE_BASE + '/book/getProgress?' + urlencode({'bookId': ident}), credentials=grant)
            if classify(native_again, ident) != (category, state):
                raise ValueError('inventory/changed')
            web.book_id = ident
            remote = web.request('progress_before', WEB_BASE + '/web/book/getProgress?' + urlencode({'bookId': ident}))
            web_state = no_chapter(remote, ident)
            remote_again = web.request('progress_after', WEB_BASE + '/web/book/getProgress?' + urlencode({'bookId': ident}))
            if no_chapter(remote_again, ident) != web_state:
                raise ValueError('inventory/changed')
            report['candidate_dual_channel_stable'] = True
            report['candidate_shelf_ordinal'] = index
            break
        if report['checked'] < len(selected):
            pause(0.5)
    after = api.request('shelf_after', NATIVE_BASE + '/shelf/sync', credentials=grant)
    if numeric_books(after) != ids or shelf_projection(after) != reference:
        raise ValueError('inventory/shelf_changed')
    report.update(result='OBSERVED', shelf_unchanged=True)
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--offset', type=int, default=0)
    parser.add_argument('--limit', type=int, default=MAX_BOOKS)
    args = parser.parse_args(argv)
    if args.offset < 0 or not 1 <= args.limit <= MAX_BOOKS:
        parser.error('invalid bounded range')
    if not args.saved_session:
        print(json.dumps({'result': 'OFFLINE_ONLY', 'account_writes': 0, 'authorization_posts': 0})); return 0
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    saved = grant = web = api = None
    report = {'result': 'UNVERIFIED', 'account_writes': 0, 'authorization_posts': 0}
    try:
        store = SessionStore(); saved = store.load(); grant = NativeSessionStore().load(saved['vid'])
        web = WebSourceProbe(); web.vid = saved['vid']
        for key, value in saved['cookies'].items(): web.set_cookie(key, value)
        web.verify_account(); api = ScopedNative(grant)
        report = inspect(api, web, grant, args.offset, args.limit)
        web.verify_account()
    except Exception:
        if api and api.report['stages']:
            status = api.report['stages'][-1].get('status')
            if type(status) is int: report['last_native_status'] = status
            report['last_native_stage'] = api.report['stages'][-1].get('stage')
            report['native_gets_attempted'] = len(api.report['stages'])
    finally:
        if web:
            if web.authenticated and saved:
                try: web.verify_account(); save_refreshed_web_session(store, saved, web)
                except Exception: report['result'] = 'UNVERIFIED'
            web.close()
        if grant: grant.clear()
        if saved: saved.clear()
    print(json.dumps(report, ensure_ascii=False))
    return 0 if report['result'] == 'OBSERVED' else 1


if __name__ == '__main__':
    raise SystemExit(main())
