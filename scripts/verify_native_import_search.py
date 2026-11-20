#!/usr/bin/env python3
"""Compare one imported-book search with native E-Ink, without account writes.

Offline by default. Source, identifiers, keywords and credentials remain in
memory; output contains only bounded structural observations and booleans.
"""
import argparse
import json
import resource
from urllib.parse import parse_qs, urlencode, urlsplit

from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_cb_book_search import SearchProbe, query_text
from verify_cb_progress import cb_id
from verify_cb_reading import baseline_position, readable_chapters
from verify_eink_login import BASE as NATIVE_BASE, NativeProbe, ProbeError
from verify_web_source_progress import BASE, versions


class ScopedNativeSearch(NativeProbe):
    def __init__(self, book, keyword, opener=None):
        super().__init__(opener)
        if not cb_id(book) or not isinstance(keyword, str) or not 1 <= len(keyword.encode()) <= 160:
            raise ValueError('scope')
        self.book, self.keyword, self.used = book, keyword, set()

    def request(self, stage, url, body=None, credentials=None, timeout=15):
        parsed = urlsplit(url)
        expected = {'bookId': [self.book], 'keyword': [self.keyword], 'count': ['10'],
                    'fragmentSize': ['150'], 'maxIdx': ['0'], 'onlyCount': ['0']}
        if (stage != 'native_search' or stage in self.used or body is not None or not credentials
                or parsed.scheme != 'https' or parsed.netloc != 'i.weread.qq.com'
                or parsed.path != '/book/search' or parsed.fragment
                or parse_qs(parsed.query, keep_blank_values=True) != expected):
            raise ValueError('scope')
        self.used.add(stage)
        return super().request(stage, url, credentials=credentials, timeout=timeout)


def shape(value, chapter, keyword, position):
    """Expose recognized shape only; do not infer coordinates from snippets."""
    top = {key: key in value for key in ('result', 'results', 'totalCount', 'hasMore', 'maxIdx')}
    rows = value.get('result', value.get('results'))
    result = {'fields_present': top, 'rows_are_list': isinstance(rows, list)}
    if not isinstance(rows, list) or len(rows) > 100:
        return result
    result.update(rows=len(rows), rows_are_objects=all(isinstance(row, dict) for row in rows))
    if not result['rows_are_objects']:
        return result
    keys = ('chapterUid', 'chapterIdx', 'abstract', 'posBegin', 'posEnd', 'matchWords')
    result['row_fields_present'] = {key: any(key in row for row in rows) for key in keys}
    result['target_chapter_present'] = any(str(row.get('chapterUid')) == chapter for row in rows)
    result['target_text_in_abstract'] = any(isinstance(row.get('abstract'), str)
                                            and keyword in row['abstract'] for row in rows)
    result['target_exact_coordinates'] = any(str(row.get('chapterUid')) == chapter
        and (row.get('posBegin'), row.get('posEnd')) == position for row in rows)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--book-index', type=int, choices=range(1, 9), default=1)
    args = parser.parse_args(argv)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    report = {'result': 'OFFLINE_ONLY', 'account_data_writes': 0, 'authentication_posts': 0,
              'native_search_gets': 0, 'private_data_saved': False}
    if not args.saved_session:
        print(json.dumps(report)); return 0
    saved = grant = None
    web = SearchProbe()
    report['result'] = 'UNVERIFIED'
    phase = 'session'
    try:
        saved = SessionStore().load()
        grant = NativeSessionStore().load(saved['vid'])
        web.vid = saved['vid']
        for key, value in saved['cookies'].items(): web.set_cookie(key, value)
        web.verify_account()
        samples = web.prepare(args.book_index)
        if len(samples) != 1 or samples[0]['source_format'] != 'web_xhtml':
            raise ValueError('source_unavailable')
        sample = samples[0]
        keyword, expected = query_text(sample['source'], (8, 4))
        if keyword is None: raise ValueError('source_unavailable')
        web.book_id, web.chapter = sample['book_id'], sample['chapter_uid']
        pos_url = BASE + '/web/book/getProgress?' + urlencode({'bookId': web.book_id})
        before = baseline_position(web.request('search_progress_before', pos_url), web.book_id)
        first, chapters = readable_chapters(web.request('search_catalog_before', BASE + '/web/book/chapterInfos',
            {'bookIds': [web.book_id]}), web.book_id)
        if before != sample['baseline'] or chapters != sample['chapters']: raise ValueError('baseline_changed')
        phase = 'native_search'
        query = dict(bookId=web.book_id, keyword=keyword, count=10, fragmentSize=150, maxIdx=0, onlyCount=0)
        native = ScopedNativeSearch(web.book_id, keyword)
        report['native_search_gets'] = 1
        try:
            response = native.request('native_search', NATIVE_BASE + '/book/search?' + urlencode(query), credentials=grant)
            report['native_response'] = shape(response, web.chapter, keyword, expected)
            report['native_response']['accepted'] = True
        except ProbeError:
            stage = native.report['stages'][-1]
            report['native_response'] = {'accepted': False, 'http_status': stage.get('status', 0),
                                         'api_rejected': 'error_code' in stage}
        phase = 'readback'
        after = baseline_position(web.request('search_progress_after', pos_url), web.book_id)
        later, later_chapters = readable_chapters(web.request('search_catalog_after', BASE + '/web/book/chapterInfos',
            {'bookIds': [web.book_id]}), web.book_id)
        shelf = web.request('shelf_after', BASE + '/web/shelf/sync')
        if (before != after or chapters != later_chapters or versions(first) != versions(later)
                or [str(row['bookId']) for row in shelf['books']] != web.shelf_ids):
            raise ValueError('baseline_changed')
        web.verify_account()
        report.update(result='NATIVE_IMPORT_SEARCH_CHECKED', position_unchanged=True,
                      catalog_unchanged=True, shelf_unchanged=True)
    except Exception as exc:
        report['phase'] = phase
        if str(exc) in {'source_unavailable', 'baseline_changed', 'scope'}: report['reason'] = str(exc)
    finally:
        web.close()
        if saved: saved.clear()
        if grant: grant.clear()
    print(json.dumps(report, ensure_ascii=False))
    return int(report['result'] != 'NATIVE_IMPORT_SEARCH_CHECKED')


if __name__ == '__main__': raise SystemExit(main())
