#!/usr/bin/env python3
"""Bounded TXT catalog/content read probe. Offline unless --saved-session.

Finds TXT metadata in an owner shelf sample, verifies the normal e_0 fallback
marker, and reads t_0/t_1 through existing content contracts. Never changes
progress, shelf, membership, trials or purchase state. Private data stays in
memory; public output contains fixed labels and counts only.
"""
import argparse
from datetime import datetime, timezone
import json
import math
from urllib.parse import urlsplit

from fetch_weread_epub import decode_content_shards, make_content_params, normalize_chapter_infos, reader_url_for, weread_e
from secure_weread_session import SessionStore, StoreError
from verify_reader_context import ContextError, project as reader_context
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE, PreflightError, WebSourceProbe, identifier


class TxtError(ValueError):
    pass


def format_kind(value):
    if value is None:
        return 'absent'
    return value if value in ('epub', 'txt', 'pdf') else 'other'


def fallback_marker(text, book_id, chapter_uid):
    if not isinstance(text, str) or len(text.encode()) > 65536:
        raise TxtError('txt_marker_invalid')
    try:
        value = json.loads(text)
    except ValueError:
        return False
    if not isinstance(value, dict) or 'bookId' not in value:
        return False
    if (identifier(value['bookId']) != book_id
            or value.get('chapterUid') is not None and identifier(value['chapterUid']) != chapter_uid
            or any(key in value and (type(value[key]) is bool or value[key] not in (0, '0', None)) for key in ('errcode', 'errCode'))
            or 'succ' in value and value['succ'] not in (True, 1, '1')):
        raise TxtError('txt_marker_invalid')
    return True


def select_chapter(chapters, preferred=None):
    seen, eligible = set(), []
    for row in chapters:
        try:
            uid = identifier(row.get('chapterUid'))
        except (PreflightError, AttributeError):
            continue
        if uid in seen:
            raise TxtError('txt_catalog_ambiguous')
        seen.add(uid)
        words = row.get('wordCount')
        if type(words) in (int, float) and math.isfinite(words) and 200 <= words <= 100000000:
            eligible.append(dict(chapterUid=uid, title=row.get('title', '')))
    for row in eligible:
        if preferred is None or row['chapterUid'] == preferred:
            return row
    raise TxtError('txt_no_readable_chapter')


class TxtProbe(WebSourceProbe):
    def __init__(self):
        super().__init__()
        self.txt_scope = False
        self.psvts = None
        self.sample = None
        self.catalog_count = 0
        self.shelf_ids, self.shelf_count = [], 0
        self.format_counts = {key: 0 for key in ('epub', 'txt', 'pdf', 'absent', 'other')}

    def guard(self, stage, url, body):
        if stage in ('t_0', 't_1'):
            parsed = urlsplit(url)
            keys = {'b', 'c', 'r', 'ct', 'ps', 'pc', 'sc', 'prevChapter', 'st', 's'}
            if (not self.authenticated or not self.txt_scope or not self.book_id or not self.chapter
                    or parsed.scheme != 'https' or parsed.netloc != 'weread.qq.com' or parsed.query or parsed.fragment
                    or parsed.path != '/web/book/chapter/' + stage or not isinstance(body, dict) or set(body) != keys
                    or body['b'] != weread_e(self.book_id) or body['c'] != weread_e(self.chapter)
                    or body['ps'] != self.psvts or type(body['sc']) is not int or body['sc'] != 1
                    or body['prevChapter'] is not False or type(body['st']) is not int or body['st'] != 0):
                raise PreflightError('txt_read_outside_scope')
            return
        super().guard(stage, url, body)

    def choose_chapter(self, chapters):
        return select_chapter(chapters)

    def find_sample(self, book_id=None, limit=8):
        self.shelf_ids, self.shelf_count, self.sample = [], 0, None
        if book_id is not None:
            candidates = [(identifier(book_id), None)]
        else:
            shelf = self.request('shelf', BASE + '/web/shelf/sync')
            rows = shelf.get('books') if isinstance(shelf, dict) else None
            if not isinstance(rows, list) or len(rows) > 5000:
                raise TxtError('txt_shelf_invalid')
            self.shelf_count = len(rows)
            candidates, seen = [], set()
            for row in sorted(rows, key=lambda item: 0 if isinstance(item, dict) and item.get('format') == 'txt' else 1):
                try:
                    key = identifier(row.get('bookId'))
                except (PreflightError, AttributeError):
                    continue
                if key not in seen:
                    self.shelf_ids.append(key)
                    if len(candidates) < limit:
                        candidates.append((key, row.get('format')))
                    seen.add(key)
        for key, hint in candidates:
            if self.inspect_book(key, hint):
                return True
        return False

    def inspect_book(self, book_id, hint=None):
        self.book_id, self.chapter, self.txt_scope = book_id, None, False
        self.sample, self.psvts = None, None
        raw = self.request('catalog_before', BASE + '/web/book/chapterInfos', dict(bookIds=[book_id]))
        record, chapters = normalize_chapter_infos(raw, book_id)
        self.catalog_count += 1
        info = record.get('book') if isinstance(record.get('book'), dict) else {}
        if info.get('bookId') is not None and identifier(info['bookId']) != book_id:
            raise TxtError('txt_catalog_foreign')
        kind = format_kind(info.get('format', hint))
        self.format_counts[kind] += 1
        if kind != 'txt':
            return False
        chapter = self.choose_chapter(chapters)
        self.chapter = chapter['chapterUid']
        url = reader_url_for(book_id, self.chapter)
        context = reader_context(dict(book_id=book_id), self.request('reader', url, as_json=False))
        if identifier(context['current_chapter'].get('chapterUid')) != self.chapter:
            raise TxtError('txt_reader_foreign_chapter')
        self.psvts = context['psvts']
        def post(name):
            return self.request(name, BASE + '/web/book/chapter/' + name,
                                make_content_params(book_id, self.chapter, self.psvts, sc=1), as_json=False)
        if not fallback_marker(post('e_0'), book_id, self.chapter):
            raise TxtError('txt_fallback_not_observed')
        self.txt_scope = True
        t0, t1 = post('t_0'), post('t_1')
        if t0 == '{}':
            raise TxtError('txt_content_unavailable')
        if t1 == '{}':
            t1 = ''
        plain = decode_content_shards(t0, t1, '')
        if not isinstance(plain, str) or not 0 < len(plain.encode()) <= 2*1024*1024 or len(plain.strip()) < 32:
            raise TxtError('txt_content_invalid')
        self.sample = dict(book_id=book_id, chapter=chapter, plain=plain, shards=[t0, t1], context=context,
                           record=record, chapters=chapters)
        return True


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--book-id')
    parser.add_argument('--sample', type=int, choices=range(1, 17), default=8)
    args = parser.parse_args(argv)
    if args.book_id and not args.saved_session:
        parser.error('--book-id requires --saved-session')
    report = dict(result='OFFLINE_ONLY', checked_at=datetime.now(timezone.utc).isoformat(),
                  account_data_writes_attempted=0, purchase_or_trial_requests=0,
                  private_source_saved=False, credentials_written_to_files=False)
    web = saved = None
    try:
        if args.saved_session:
            store, web = SessionStore(), TxtProbe()
            saved = store.load(); web.vid = saved['vid']
            for key, value in saved['cookies'].items():
                web.set_cookie(key, value)
            web.verify_account()
            try:
                web.find_sample(args.book_id, args.sample)
                if not args.book_id:
                    report['shelf_books'] = web.shelf_count
            finally:
                web.verify_account()
                report['cookie_rotation_saved'] = save_refreshed_web_session(store, saved, web)
            if web.sample:
                plain = web.sample['plain']
                report.update(result='TXT_READ_CONTRACT_VERIFIED', fallback_marker_verified=True, same_book_chapter=True,
                              plain_bytes=len(plain.encode()), plain_utf16_units=len(plain.encode('utf-16-le'))//2,
                              t1_present=bool(web.sample['shards'][1]), raw_text_kept_in_memory=True)
            else:
                report.update(result='NO_TXT_IN_BOUNDED_SAMPLE', txt_read_contract_verified=False)
    except (StoreError, PreflightError, ContextError, TxtError, ValueError, TypeError):
        report.update(result='UNVERIFIED', reason='txt_reading_unverified')
    except Exception:
        report.update(result='UNVERIFIED', reason='txt_reading_probe_failed')
    finally:
        if web:
            report.update(catalogs_checked=web.catalog_count, catalog_format_counts=web.format_counts,
                          stages=[{key: row[key] for key in ('stage', 'status') if key in row} for row in web.report['stages']])
            web.sample = None; web.close()
        if saved:
            saved.clear()
    print(json.dumps(report, indent=2))
    return 0 if report['result'] in ('OFFLINE_ONLY', 'TXT_READ_CONTRACT_VERIFIED', 'NO_TXT_IN_BOUNDED_SAMPLE') else 1


if __name__ == '__main__':
    raise SystemExit(main())
