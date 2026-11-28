#!/usr/bin/env python3
"""Bounded read-only E-Ink review probe; default performs no network request.

The optional child receives source data through stdin and must return it only
through its captured stdout. Never print book IDs, comments, names or tokens.
"""
import argparse
import json
import resource
import subprocess
from urllib.parse import parse_qs, urlencode, urlsplit

from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_eink_login import BASE, NativeProbe

resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


class ScopedProbe(NativeProbe):
    def __init__(self):
        super().__init__()
        self.ids = set()

    def request(self, stage, url, body=None, credentials=None, timeout=15):
        u = urlsplit(url)
        q = parse_qs(u.query)
        valid = body is None and u.scheme == 'https' and u.netloc == 'i.weread.qq.com' and not u.fragment
        if stage == 'shelf':
            valid = valid and u.path == '/shelf/sync' and not q
        elif stage == 'reviews':
            valid = valid and u.path == '/review/list' and set(q) == {
                'bookId', 'listType', 'listMode', 'synckey', 'count', 'maxIdx', 'tips'}
            valid = valid and all(len(v) == 1 for v in q.values()) and q['bookId'][0] in self.ids
            valid = valid and q['listType'] == ['3'] and q['listMode'] == ['1'] and q['synckey'] == ['0']
            valid = valid and q['count'] in (['21'], ['41']) and q['maxIdx'] == ['0'] and q['tips'] == ['1']
        else:
            valid = False
        if not valid:
            raise ValueError('request_outside_scope')
        return super().request(stage, url, body, credentials, timeout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--lua-command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not args.saved_session and not args.lua_command:
        print(json.dumps({'result': 'OFFLINE_ONLY', 'requests': 0}))
        return 0
    if not args.saved_session or not args.lua_command:
        parser.error('saved session and private Lua command are required together')
    probe = ScopedProbe()
    credentials = None
    report = {'result': 'UNVERIFIED', 'account_writes': 0, 'samples': []}
    try:
        credentials = NativeSessionStore().load(SessionStore().load()['vid'])
        shelf = probe.request('shelf', BASE + '/shelf/sync', credentials=credentials)
        books = shelf.get('books')
        if not isinstance(books, list) or len(books) > 5000:
            raise ValueError('shelf_invalid')
        ids = []
        for book in books:
            value = str(book.get('bookId', '')) if isinstance(book, dict) else ''
            if value.isascii() and value.isdigit() and not value.startswith('0') and len(value) <= 20 and value not in ids:
                ids.append(value)
            if len(ids) == 2:
                break
        if len(ids) != 2:
            raise ValueError('insufficient_books')
        probe.ids = set(ids)
        samples = []
        for book_id in ids:
            pages = []
            for count in (21, 41):
                q = dict(bookId=book_id, listType=3, listMode=1, synckey=0, count=count, maxIdx=0, tips=1)
                pages.append(probe.request('reviews', BASE + '/review/list?' + urlencode(q), credentials=credentials))
            samples.append(dict(book_id=book_id, first=pages[0], second=pages[1]))
        encoded = json.dumps(dict(samples=samples), ensure_ascii=False, separators=(',', ':')).encode()
        if len(encoded) > 8 * 1024 * 1024:
            raise ValueError('input_too_large')
        child = subprocess.run(args.lua_command, input=encoded, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=60)
        if child.returncode or len(child.stdout) > 8 * 1024 * 1024:
            raise ValueError('lua_failed')
        result = json.loads(child.stdout)
        if not isinstance(result, dict) or not isinstance(result.get('samples'), list) or len(result['samples']) != 2:
            raise ValueError('lua_result_invalid')
        for sample, actual in zip(samples, result['samples']):
            entry = {}
            for name, limit in (('first', 20), ('second', 40)):
                raw = sample[name].get('reviews')
                page = actual.get(name)
                if not isinstance(raw, list) or not isinstance(page, dict) or not isinstance(page.get('items'), list):
                    raise ValueError('page_invalid')
                if len(page['items']) != min(limit, len(raw)) or page.get('has_more') != (len(raw) > limit):
                    raise ValueError('count_mismatch')
                for native, projected in zip(raw, page['items']):
                    review = native['review']
                    author = review.get('author') or {}
                    expected_name = (author.get('nick') or author.get('name') or author.get('userName') or author.get('username') or '').strip()
                    if projected.get('review_id') != review['reviewId'] or projected.get('author') != expected_name:
                        raise ValueError('identity_or_author_mismatch')
                    if projected.get('rating') != (review.get('star') or 0) / 20 or projected.get('create_time') != review['createTime']:
                        raise ValueError('rating_or_time_mismatch')
                entry[name + '_count'] = len(page['items'])
                entry[name + '_more'] = page['has_more']
            report['samples'].append(entry)
        report.update(result='NATIVE_REVIEW_MODEL_VERIFIED', requests=len(probe.report['stages']))
    except Exception as exc:
        report.update(result='UNVERIFIED', reason=type(exc).__name__, requests=len(probe.report['stages']),
                      stages=[{'stage': stage.get('stage'), 'status': stage.get('status')}
                              for stage in probe.report['stages']])
    finally:
        if credentials:
            credentials.clear()
    print(json.dumps(report, ensure_ascii=False))
    return 0 if report['result'] == 'NATIVE_REVIEW_MODEL_VERIFIED' else 1


if __name__ == '__main__':
    raise SystemExit(main())
