#!/usr/bin/env python3
"""Read-only independent HTTP comparison. Credentials travel only through pipes."""
import argparse
import json
import resource
import subprocess
from urllib.parse import urlencode
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_eink_login import BASE
from verify_native_book_reviews import ScopedProbe

resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--native-ui', action='store_true')
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
            raise ValueError('invalid_shelf')
        ids = [str(b.get('bookId', '')) for b in books if isinstance(b, dict)]
        book = next(v for v in ids if v.isascii() and v.isdigit() and not v.startswith('0') and len(v) <= 20)
        probe.ids = {book}
        pages = []
        for count in (21, 41):
            q = dict(bookId=book, listType=3, listMode=1, synckey=0, count=count, maxIdx=0, tips=1)
            pages.append(probe.request('reviews', BASE + '/review/list?' + urlencode(q), credentials=credentials))
        payload = json.dumps(dict(credentials=credentials, book_id=book, first=pages[0], second=pages[1]),
                             ensure_ascii=False, separators=(',', ':')).encode()
        if len(payload) > 8 * 1024 * 1024:
            raise ValueError('input_too_large')
        child = subprocess.run(args.lua_command, input=payload, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=90)
        marker = b'\nWEREAD_NATIVE_REVIEWS_UI=' if args.native_ui else b'\nWEREAD_NATIVE_REVIEWS_HTTP='
        if child.returncode or len(child.stdout) > 65536 or child.stdout.count(marker) != 1:
            raise ValueError('lua_failed')
        result = json.loads(child.stdout.split(marker)[1])
        report.update(lua=result, python_requests=len(probe.report['stages']))
        expected = {'result': 'PASS', 'phase': 'complete', 'requests': 2}
        if args.native_ui:
            expected.update(painted=True, heartbeat=True)
        if result != expected:
            raise ValueError('comparison_failed')
        report['result'] = 'NATIVE_UI_VERIFIED' if args.native_ui else 'NATIVE_HTTP_VERIFIED'
    except Exception as exc:
        report.update(reason=type(exc).__name__, python_requests=len(probe.report['stages']),
                      stages=[{'stage': stage.get('stage'), 'status': stage.get('status')}
                              for stage in probe.report['stages']])
    finally:
        if credentials:
            credentials.clear()
    print(json.dumps(report, ensure_ascii=False))
    return 0 if report['result'] in ('NATIVE_HTTP_VERIFIED', 'NATIVE_UI_VERIFIED') else 1


if __name__ == '__main__':
    raise SystemExit(main())
