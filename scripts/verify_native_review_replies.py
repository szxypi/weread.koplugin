#!/usr/bin/env python3
"""Bounded read-only review/reply UI verification; private pipes only."""
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
        self.books = set()
        self.review = None

    def request(self, stage, url, body=None, credentials=None, timeout=15):
        u = urlsplit(url)
        q = parse_qs(u.query)
        valid = body is None and u.scheme == 'https' and u.netloc == 'i.weread.qq.com' and not u.fragment
        if stage == 'shelf':
            valid = valid and u.path == '/shelf/sync' and not q
        elif stage == 'list':
            valid = valid and u.path == '/review/list' and set(q) == {
                'bookId', 'listType', 'listMode', 'synckey', 'count', 'maxIdx', 'tips'}
            valid = valid and all(len(v) == 1 for v in q.values()) and q['bookId'][0] in self.books
            valid = valid and q['listType'] == ['3'] and q['listMode'] == ['1'] and q['synckey'] == ['0']
            valid = valid and q['count'] == ['61'] and q['maxIdx'] == ['0'] and q['tips'] == ['1']
        elif stage == 'reply':
            valid = valid and u.path == '/review/single' and set(q) == {
                'reviewId', 'commentsCount', 'commentsDirection', 'likesCount', 'synckey'}
            valid = valid and all(len(v) == 1 for v in q.values()) and q['reviewId'] == [self.review]
            valid = valid and q['commentsCount'] in (['21'], ['41']) and q['commentsDirection'] == ['0']
            valid = valid and q['likesCount'] == ['0'] and q['synckey'] == ['0']
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
    probe, credentials = ScopedProbe(), None
    report = {'result': 'UNVERIFIED', 'account_writes': 0}
    try:
        credentials = NativeSessionStore().load(SessionStore().load()['vid'])
        shelf = probe.request('shelf', BASE + '/shelf/sync', credentials=credentials)
        books = shelf.get('books')
        if not isinstance(books, list) or len(books) > 5000:
            raise ValueError('shelf_invalid')
        ids = []
        for row in books:
            value = str(row.get('bookId', '')) if isinstance(row, dict) else ''
            if value.isascii() and value.isdigit() and not value.startswith('0') and len(value) <= 20 and value not in ids:
                ids.append(value)
            if len(ids) == 4:
                break
        probe.books = set(ids)
        target = None
        for book_id in ids:
            q = dict(bookId=book_id, listType=3, listMode=1, synckey=0, count=61, maxIdx=0, tips=1)
            listing = probe.request('list', BASE + '/review/list?' + urlencode(q), credentials=credentials)
            rows = listing.get('reviews')
            if not isinstance(rows, list) or len(rows) > 61:
                raise ValueError('review_list_invalid')
            for index, row in enumerate(rows[:60]):
                if not isinstance(row, dict):
                    continue
                count, rid = row.get('commentsCount'), row.get('reviewId')
                if type(count) is int and count >= 21 and isinstance(rid, str) and rid and len(rid) <= 256:
                    target = (book_id, rid, index + 1, listing)
                    break
            if target:
                break
        if not target:
            raise ValueError('no_review_with_enough_replies')
        book_id, review_id, index, listing = target
        probe.review = review_id
        replies = []
        for count in (21, 41):
            q = dict(reviewId=review_id, commentsCount=count, commentsDirection=0, likesCount=0, synckey=0)
            replies.append(probe.request('reply', BASE + '/review/single?' + urlencode(q), credentials=credentials))
        payload = json.dumps(dict(credentials=credentials, book_id=book_id, review_id=review_id, review_index=index,
                                  listing=listing, first=replies[0], second=replies[1]),
                             ensure_ascii=False, separators=(',', ':')).encode()
        if len(payload) > 8 * 1024 * 1024:
            raise ValueError('input_too_large')
        child = subprocess.run(args.lua_command, input=payload, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=120)
        marker = b'\nWEREAD_NATIVE_REPLIES_UI='
        if child.returncode or len(child.stdout) > 65536 or child.stdout.count(marker) != 1:
            raise ValueError('lua_failed')
        result = json.loads(child.stdout.split(marker)[1])
        report.update(lua=result, python_requests=len(probe.report['stages']))
        if result.get('result') != 'PASS' or result.get('phase') != 'complete' or result.get('requests') != 5 \
                or result.get('painted') is not True or result.get('heartbeat') is not True:
            raise ValueError('comparison_failed')
        report['result'] = 'NATIVE_REPLIES_UI_VERIFIED'
    except Exception as exc:
        report.update(reason=type(exc).__name__, python_requests=len(probe.report['stages']),
                      stages=[{'stage': s.get('stage'), 'status': s.get('status')} for s in probe.report['stages']])
    finally:
        if credentials:
            credentials.clear()
    print(json.dumps(report, ensure_ascii=False))
    return 0 if report['result'] == 'NATIVE_REPLIES_UI_VERIFIED' else 1


if __name__ == '__main__':
    raise SystemExit(main())
