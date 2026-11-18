#!/usr/bin/env python3
"""Find a fully accessible translated-book candidate without account writes.

Offline unless --saved-session is specified. Only the fixed public English
queries and bounded shelf, membership, metadata, catalog and chapter reads
from the existing translation probes are permitted. Identifiers and source
content stay in memory; output contains fixed labels, counts and booleans.
"""
import argparse
import json
import resource
from urllib.parse import urlencode

from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from shelf_flag_change_contract import state_hash
from verify_eink_login import BASE, ProbeError
from verify_translation_generation import Native, Web
from verify_translation_preflight import PUBLIC_QUERIES, TranslationError, catalog, catalog_body, save_refreshed_web_session
from verify_native_discovery import identity

MAX_CHAPTERS = 64
MAX_SHELF_BOOKS = 30


def shelf_english_ids(shelf):
    rows = shelf.get('books') if isinstance(shelf, dict) else None
    if not isinstance(rows, list) or len(rows) > 5000: raise ValueError('discovery/shelf_invalid')
    found, seen = [], set()
    for row in rows:
        if not isinstance(row, dict): continue
        nested = row.get('bookInfo', row.get('book'))
        nested = nested if isinstance(nested, dict) else {}
        book = identity(row.get('bookId'))
        if not book or nested.get('bookId') is not None and identity(nested['bookId']) != book: continue
        title = row.get('title', nested.get('title'))
        if not isinstance(title, str) or len(title.encode()) > 4096 or any(ord(c) < 32 or ord(c) == 127 for c in title): continue
        letters = sum(c.isascii() and c.isalpha() for c in title)
        if letters >= 10 and letters / max(1, len(title)) >= 0.6 and book not in seen:
            seen.add(book); found.append(book)
    return found[:MAX_SHELF_BOOKS], len(found) > MAX_SHELF_BOOKS


def eligible(sample):
    """Mirror the downloader's readable selection, requiring explicit access."""
    if not isinstance(sample, dict) or not isinstance(sample.get('expected'), dict): return None
    model, raw = sample['expected'], sample.get('source')
    if model.get('format') != 'epub' or not isinstance(raw, dict) or not isinstance(raw.get('data'), list): return None
    record = [row for row in raw['data'] if isinstance(row, dict) and str(row.get('bookId')) == model.get('book_id')]
    if len(record) != 1 or not isinstance(record[0].get('updated'), list): return None
    rows, chapters = record[0]['updated'], model.get('chapters')
    if not isinstance(chapters, list) or len(rows) != len(chapters): return None
    selected = []
    for raw_row, projected in zip(rows, chapters):
        if not isinstance(raw_row, dict) or not isinstance(projected, dict): return None
        if str(raw_row.get('chapterUid')) != str(projected.get('uid')): return None
        words = raw_row.get('wordCount', 0)
        if type(words) not in (int, float) or words != words or words < 0 or words > 100000000: return None
        if words > 0 and str(raw_row.get('title', '')) != '封面':
            if type(projected.get('uid')) is not int or projected['uid'] <= 0 or projected.get('free_or_owned') is not True:
                return None
            selected.append(projected)
    if not 2 <= len(selected) <= MAX_CHAPTERS: return None
    return selected


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--book-offset', type=int, choices=range(0, 19), default=0)
    parser.add_argument('--query', choices=PUBLIC_QUERIES, help='search a single fixed public title')
    parser.add_argument('--shelf', action='store_true')
    args = parser.parse_args(argv)
    if args.shelf and (args.book_offset or args.query): parser.error('query and book offset are for public discovery only')
    report = dict(result='OFFLINE_ONLY', public_queries=0, books_checked=0, candidates=0, book_offset=args.book_offset,
                  source='shelf' if args.shelf else 'public', account_data_writes=0, authentication_posts=0, private_data_saved=False)
    if not args.saved_session:
        print(json.dumps(report)); return 0
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    saved = grant = web = None
    report['result'] = 'UNVERIFIED'
    phase = 'session'
    try:
        session = SessionStore(); saved = session.load(); grant = NativeSessionStore().load(saved['vid'])
        web = Web(); web.vid = saved['vid']
        for key, value in saved['cookies'].items(): web.set_cookie(key, value)
        web.verify_account()
        first = Native(); shelf = first.request('shelf', BASE + '/shelf/sync', credentials=grant)
        original_shelf = state_hash(shelf)
        phase = 'discovery'
        def samples():
            nonlocal probe
            if args.shelf:
                ids, truncated = shelf_english_ids(shelf)
                report.update(shelf_books_selected=len(ids), shelf_selection_truncated=truncated)
                probe = first; probe.allowed_ids = set(ids)
                for index, book in enumerate(ids, 1):
                    info = probe.request('book', BASE + '/book/info?' + urlencode(dict(bookId=book)), credentials=grant)
                    raw = probe.request('catalog', BASE + '/book/chapterInfos', body=catalog_body(book), credentials=grant)
                    yield None, index, dict(book_id=book, info=info, source=raw, expected=catalog(raw,book,info))
            else:
                for query_index, query in enumerate(PUBLIC_QUERIES, 1):
                    if args.query and query != args.query: continue
                    probe = Native(public_query=query)
                    report['public_queries'] += 1
                    try:
                        probe.inspect(grant, 2, True, book_offset=args.book_offset)
                    except TranslationError as error:
                        if str(error) == 'translation/no_eligible_sample': continue
                        raise
                    for index, sample in enumerate(probe.samples, 1):
                        yield query_index, args.book_offset+index, sample
        probe = first
        for query_index, book_index, sample in samples():
                report['books_checked'] += 1
                selected = eligible(sample)
                if not selected: continue
                readable = [row for row in selected if type(row.get('wordCount')) is int and row['wordCount'] >= 200]
                if not readable: continue
                target = max(readable, key=lambda row: (row.get('transWordCount', 0) > 0,
                    row.get('translateVersion', 0) > 0, row.get('hasTranslated') is True))
                # Only the already admitted chapter is fetched. Metadata flags
                # do not prove that actual translated text exists.
                phase = 'content'
                checked = web.inspect_content(sample, target['uid'])
                if checked.get('nonempty_translation_blocks', 0) > 0:
                    report.update(candidates=1, book_index=book_index, readable_chapters=len(selected), translated_chapter_confirmed=True)
                    if query_index is not None: report['query_index'] = query_index
                    break
                phase = 'discovery'
        phase = 'readback'
        final_shelf = state_hash(first.request('shelf', BASE + '/shelf/sync', credentials=grant))
        if final_shelf != original_shelf: raise ValueError('discovery/shelf_changed')
        web.verify_account()
        if session.load() != saved or NativeSessionStore().load(saved['vid']) != grant: raise ValueError('discovery/session_changed')
        save_refreshed_web_session(session, saved, web)
        report.update(result='FULL_TRANSLATION_DISCOVERY_CHECKED', shelf_unchanged=True)
    except ProbeError:
        report['phase'] = phase
        if phase == 'discovery' and 'probe' in locals() and probe.report['stages']:
            report['http_status'] = probe.report['stages'][-1].get('status', 0)
    except Exception as error:
        report['phase'] = phase
        if str(error) in ('discovery/shelf_changed', 'discovery/session_changed'):
            report['reason'] = str(error)
    finally:
        if web: web.close()
        if saved: saved.clear()
        if grant: grant.clear()
    print(json.dumps(report))
    return int(report['result'] != 'FULL_TRANSLATION_DISCOVERY_CHECKED')


if __name__ == '__main__': raise SystemExit(main())
