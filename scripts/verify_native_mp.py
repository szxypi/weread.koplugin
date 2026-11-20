#!/usr/bin/env python3
"""Opt-in native MP catalog reads; no account writes, renewal or saved articles.

Protocol reference: weread-omni 88bd2e095d7d7ee423eaadf8f40653e72c5be6d4,
src/api/resources/public-accounts.ts (MIT, Copyright 2026 Teng Lin).
First requests use synckey=0; later pages use offset without synckey.
"""
import argparse
from datetime import datetime, timezone
import json
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request

from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_eink_login import BASE, HEADERS, NativeProbe, ProbeError
from verify_mp_catalog import book_id
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import WebSourceProbe, identifier

COUNT = 20
ERROR_LIMIT = 65536
RESPONSE_LIMIT = 4 * 1024 * 1024
ROW_FIELDS = {'reviewId', 'title', 'createTime', 'mpInfo', 'originalId', 'bookId', 'review', 'id',
              'chapterUid', 'chapterIdx', 'url', 'author', 'time'}


def error_code(value):
    """Accept consistent bounded integers only; never publish an error message."""
    codes = [value[key] for key in ('errCode', 'errcode') if key in value]
    if not codes:
        return None
    if (any(type(code) is not int or not -(2 ** 31) <= code < 2 ** 31 for code in codes)
            or len(set(codes)) != 1):
        raise ValueError('native_mp_error_code_invalid')
    return codes[0]


class ErrorObservation:
    """Retain bounded error types/codes, never an error message or raw body."""
    def __init__(self, opener):
        self.opener = opener
        self.last = None

    def open(self, request, **kwargs):
        self.last = None
        try:
            return self.opener.open(request, **kwargs)
        except HTTPError as exc:
            try:
                raw = exc.read(ERROR_LIMIT + 1)
                self.last = dict(error_response_bounded=len(raw) <= ERROR_LIMIT,
                                 error_response_bytes=min(len(raw), ERROR_LIMIT + 1))
                if len(raw) <= ERROR_LIMIT:
                    try:
                        value = json.loads(raw)
                    except (ValueError, UnicodeError):
                        value = None
                    self.last['error_json_object'] = isinstance(value, dict)
                    if isinstance(value, dict):
                        try:
                            code = error_code(value)
                        except ValueError:
                            code = None
                        if code is not None:
                            self.last['error_code'] = code
            finally:
                exc.close()
            raise


class NativeMPProbe(NativeProbe):
    def __init__(self, opener=None):
        super().__init__(opener)
        self.opener = ErrorObservation(self.opener)
        self.allowed = {('mp_shelf', BASE + '/shelf/sync')}
        self.started = False
        self.summary = dict(shelf_verified=False, catalog_response_verified=False, pages=[])

    def request(self, stage, url, body=None, credentials=None, timeout=15):
        if body is not None or (stage, url) not in self.allowed:
            raise ValueError('native_mp_scope')
        self.allowed.remove((stage, url))
        record = dict(stage=stage)
        self.report['stages'].append(record)
        headers = HEADERS.copy()
        if credentials:
            headers.update(vid=credentials['vid'], accessToken=credentials['accessToken'])
        request = Request(url, headers=headers, method='GET')
        try:
            with self.opener.open(request, timeout=timeout) as response:
                record['status'] = response.status
                raw = response.read(RESPONSE_LIMIT + 1)
                if len(raw) > RESPONSE_LIMIT:
                    raise ProbeError('native_mp_response_too_large')
                value = json.loads(raw)
            if not isinstance(value, dict):
                raise ProbeError('native_mp_response_invalid')
            code = error_code(value)
            if code is not None:
                record['error_code'] = code
            if code not in (None, 0):
                raise ProbeError('native_mp_request_rejected')
            return value
        except HTTPError as exc:
            record['status'] = exc.code
            exc.close()
            raise ProbeError('native_mp_http_rejected') from None
        except (ValueError, UnicodeError, URLError, OSError):
            raise ProbeError('native_mp_response_unavailable') from None
        finally:
            if self.opener.last:
                record.update(self.opener.last)

    def inspect(self, credentials, pages):
        if self.started or type(pages) is not int or pages not in (1, 2):
            raise ValueError('native_mp_scope')
        self.started = True
        shelf = self.request('mp_shelf', BASE + '/shelf/sync', credentials=credentials)
        books = shelf.get('books') if isinstance(shelf, dict) else None
        if not isinstance(books, list) or len(books) > 5000:
            raise ValueError('native_mp_shelf_invalid')
        accounts = [row['bookId'] for row in books if isinstance(row, dict) and book_id(row.get('bookId'))]
        self.summary.update(shelf_verified=True, shelf_books=len(books), shelf_accounts=len(accounts))
        if not accounts:
            raise ValueError('native_mp_accounts_missing')
        selected = accounts[0]
        offset = 0
        for index in range(pages):
            query = dict(bookId=selected, count=COUNT)
            query['synckey' if index == 0 else 'offset'] = 0 if index == 0 else offset
            url = BASE + '/mp/chapters?' + urlencode(query)
            self.allowed.add(('native_mp_catalog', url))
            value = self.request('native_mp_catalog', url, credentials=credentials)
            rows = value.get('data')
            if not isinstance(rows, list) or len(rows) > COUNT or any(not isinstance(row, dict) for row in rows):
                raise ValueError('native_mp_catalog_invalid')
            observation = dict(page=index + 1, returned_rows=len(rows),
                               root_fields={name: type(value[name]).__name__ for name in ('data', 'hasMore', 'synckey') if name in value},
                               review_id_rows=sum(isinstance(row.get('reviewId'), str) and bool(row['reviewId']) for row in rows),
                               row_fields={key: sorted({type(row[key]).__name__ for row in rows if key in row})
                                           for key in sorted(ROW_FIELDS) if any(key in row for row in rows)})
            self.summary['pages'].append(observation)
            offset += len(rows)
            # Reference behavior only: this has not passed a live success response.
            # synckey is a delta token, never a page offset.
            if len(rows) < COUNT:
                break
        self.summary.update(catalog_response_verified=True, sampled_accounts=1)
        return self.summary


def failure_reason(stages):
    if not stages:
        return 'native_mp_catalog_preflight_failed'
    last = stages[-1]
    if last.get('error_code') == -2041:
        return 'native_mp_human_verification_required'
    if last.get('status') == 401 or last.get('error_code') == -2012:
        return 'native_mp_authentication_rejected'
    if last.get('status') == 429 or last.get('error_code') == -2014:
        return 'native_mp_read_limited'
    return 'native_mp_catalog_preflight_failed'


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--pages', type=int, choices=(1, 2), default=1)
    args = parser.parse_args(argv)
    report = dict(result='OFFLINE_ONLY', checked_at=datetime.now(timezone.utc).isoformat(),
                  account_data_writes=0, authentication_posts=0, private_catalog_saved=False,
                  credentials_written_to_files=False)
    if not args.saved_session:
        print(json.dumps(report, indent=2))
        return 0
    probe, web, saved, credentials = NativeMPProbe(), WebSourceProbe(), {}, None
    try:
        store = SessionStore()
        saved = store.load()
        web.vid = identifier(saved['vid'])
        for name, value in saved['cookies'].items():
            web.set_cookie(name, value)
        web.verify_account()
        report['web_cookie_rotation_saved'] = save_refreshed_web_session(store, saved, web)
        credentials = NativeSessionStore().load(saved['vid'])
        report.update(probe.inspect(credentials, args.pages))
        report.update(result='NATIVE_MP_CATALOG_RESPONSE_VERIFIED', owner_verified=True)
    except Exception:
        report.update(result='UNVERIFIED', reason=failure_reason(probe.report['stages']))
    finally:
        report.update(probe.summary, native_stages=probe.report['stages'], web_stages=web.report['stages'])
        if credentials:
            credentials.clear()
        saved.clear()
        web.close()
    print(json.dumps(report, indent=2))
    return 0 if report['result'] == 'NATIVE_MP_CATALOG_RESPONSE_VERIFIED' else 1


if __name__ == '__main__':
    raise SystemExit(main())
