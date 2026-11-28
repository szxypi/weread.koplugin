#!/usr/bin/env python3
"""Bounded read-only catalog quality observations; offline by default.

With --saved-session, inspect at most three existing shelf books twice using the
fixed read-only catalog endpoint. Never print/store book IDs, titles, cookies,
chapter rows or progress; never renew credentials or issue account-data writes.
"""
import argparse
import json
import math
from datetime import datetime, timezone

from fetch_weread_epub import normalize_chapter_infos
from secure_weread_session import SessionStore, _same_revision
from verify_web_source_progress import BASE, WebSourceProbe, PreflightError, identifier


def weight(value):
    if isinstance(value, bool) or not isinstance(value, (str, int, float)):
        return None
    try:
        result = float(value)
    except ValueError:
        return None
    return result if math.isfinite(result) and result > 0 and result <= 1e9 and result.is_integer() else None


def project(rows):
    if not isinstance(rows, list) or not 1 <= len(rows) <= 10000:
        raise ValueError('catalog_invalid')
    seen = set()
    values = []
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError('catalog_invalid')
        uid = identifier(row.get('chapterUid'))
        if uid in seen:
            raise ValueError('catalog_duplicate')
        seen.add(uid)
        values.append((uid, weight(row.get('wordCount'))))
    return values


def inspect(saved, store, factory=WebSourceProbe):
    probe = factory()
    try:
        probe.vid = identifier(saved['vid'])
        for key, value in saved['cookies'].items():
            probe.set_cookie(key, value)
        probe.verify_account()
        shelf = probe.request('shelf', BASE+'/web/shelf/sync')
        books = shelf.get('books') if isinstance(shelf, dict) else None
        if not isinstance(books, list) or len(books)>5000:
            raise ValueError('shelf_invalid')
        chosen = []
        for entry in books:
            if not isinstance(entry, dict):
                continue
            item = entry
            for _ in range(4):
                nested = item.get('bookInfo', item.get('book'))
                if not isinstance(nested, dict):
                    break
                item = nested
            try:
                book_id = identifier(item.get('bookId'))
            except (ValueError, PreflightError):
                continue
            if any(book_id == row[0] for row in chosen):
                continue
            chosen.append((book_id, item))
            if len(chosen)==3:
                break
        if not chosen:
            raise ValueError('no_numeric_books')
        report = dict(books=0, normalized_rows=0, normalization_omitted_rows=0, positive_weight_rows=0, books_all_positive=0,
                      count_hints_present=0, count_hints_match_filtered=0,
                      double_read_consistent=True)
        for book_id, item in chosen:
            if not _same_revision(saved, store.load()):
                raise ValueError('session_changed')
            probe.book_id = book_id
            first = probe.request('catalog_before', BASE+'/web/book/chapterInfos', {'bookIds':[book_id]})
            second = probe.request('catalog_after', BASE+'/web/book/chapterInfos', {'bookIds':[book_id]})
            record, rows = normalize_chapter_infos(first, book_id)
            _, later = normalize_chapter_infos(second, book_id)
            raw_rows = record.get('updated') or record.get('chapterInfos') or record.get('chapters') or []
            if not isinstance(raw_rows, list):
                raise ValueError('catalog_invalid')
            projected = project(rows)
            if projected != project(later):
                raise ValueError('catalog_changed')
            count = sum(value is not None for _, value in projected)
            report['books'] += 1
            report['normalized_rows'] += len(projected)
            report['normalization_omitted_rows'] += len(raw_rows)-len(rows)
            report['positive_weight_rows'] += count
            report['books_all_positive'] += count == len(projected)
            hint = item.get('totalChapter')
            if type(hint) is int and 1 <= hint <= 10000:
                report['count_hints_present'] += 1
                report['count_hints_match_filtered'] += hint == count
        probe.book_id = None
        probe.verify_account()
        if not _same_revision(saved, store.load()):
            raise ValueError('session_changed')
        return report
    finally:
        probe.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    args = parser.parse_args()
    report = dict(result='OFFLINE_ONLY', checked_at=datetime.now(timezone.utc).isoformat(),
                  account_data_writes=0, authorization_requests=0, private_data_saved=False)
    if args.saved_session:
        try:
            store = SessionStore()
            saved = store.load()
            report.update(inspect(saved, store))
            report['result'] = 'READ_ONLY_CATALOG_OBSERVED'
        except Exception:
            report['result'] = 'UNVERIFIED'
    else:
        assert project([{'chapterUid':1,'wordCount':100}]) == [('1',100.0)]
        assert weight(0) is None and weight('bad') is None and weight(True) is None
    print(json.dumps(report, ensure_ascii=False))
    return 0 if report['result'] != 'UNVERIFIED' else 1


if __name__ == '__main__':
    raise SystemExit(main())
