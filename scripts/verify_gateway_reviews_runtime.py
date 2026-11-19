#!/usr/bin/env python3
"""Synthetic local HTTP + real KOReader review widgets and worker."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        try:
            parsed = urlsplit(self.path)
            query = parse_qs(parsed.query)
            if parsed.path != '/__proxy' or query != {'url': ['https://i.weread.qq.com/api/agent/gateway']}:
                raise ValueError('outside_mock_scope')
            length = int(self.headers.get('Content-Length', '-1'))
            if not 0 <= length <= 8192 or self.headers.get('Authorization') or self.headers.get('Cookie'):
                raise ValueError('unexpected_request')
            value = json.loads(self.rfile.read(length))
            if value.get('api_name') != '/review/list' or value.get('bookId') != '42' or value.get('count') != 20 \
                    or value.get('reviewListType') not in (1, 3):
                raise ValueError('unexpected_payload')
            cursor = value.get('maxIdx')
            if cursor not in (None, 20) or cursor is not None and value.get('synckey') != 123:
                raise ValueError('unexpected_cursor')
            self.server.calls.append(value)
            time.sleep(0.2)
            start = cursor + 1 if cursor is not None else 1
            prefix = 'recommended-' if value['reviewListType'] == 1 else 'latest-'
            rows = []
            for index in range(start, start + 20):
                rid = prefix + str(index)
                rows.append({'idx': index, 'review': {'reviewId': rid, 'review': {
                    'reviewId': rid, 'bookId': '42', 'author': {'name': '合成读者'},
                    'content': '合成书评 ' + str(index), 'star': 100, 'createTime': 1700001000 - index}}})
            data = json.dumps({'reviews': rows, 'reviewsHasMore': 0 if cursor else 1, 'synckey': 123},
                              ensure_ascii=False).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (ValueError, TypeError, KeyError, json.JSONDecodeError):
            self.server.invalid += 1
            self.send_error(400)

    def log_message(self, *_args):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--width', type=int, default=600)
    parser.add_argument('--height', type=int, default=800)
    parser.add_argument('--dpi', type=int, default=167)
    args = parser.parse_args()
    runtime = args.koreader.resolve()
    if not (runtime / 'luajit').is_file() or min(args.width, args.height, args.dpi) < 1:
        parser.error('valid KOReader runtime and dimensions required')
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.calls, server.invalid = [], 0
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='weread-gateway-review-') as root:
            env = dict(os.environ, KO_HOME=root, SDL_VIDEODRIVER='dummy', EMULATE_READER='1',
                       EMULATE_BW_SCREEN='1', EMULATE_BB_TYPE='BB8', EMULATE_READER_W=str(args.width),
                       EMULATE_READER_H=str(args.height), EMULATE_READER_DPI=str(args.dpi),
                       LD_LIBRARY_PATH=str(runtime / 'libs'), WEREAD_GATEWAY_MOCK_PORT=str(server.server_port))
            child = subprocess.run([str(runtime / 'luajit'), '/source/spec/koreader/gateway_book_reviews_smoke.lua'],
                                   cwd=runtime, env=env, capture_output=True, timeout=90)
        expected = [(1, None), (1, 20), (3, None)]
        got = [(row.get('reviewListType'), row.get('maxIdx')) for row in server.calls]
        if child.returncode or b'GATEWAY_BOOK_REVIEWS_SMOKE_PASS' not in child.stdout or server.invalid or got != expected:
            print(json.dumps({'result': 'UNVERIFIED', 'exit': child.returncode, 'mock_requests': len(server.calls),
                              'invalid_requests': server.invalid, 'expected_sequence': got == expected}))
            return 1
        print(json.dumps({'result': 'SYNTHETIC_GATEWAY_HTTP_UI_VERIFIED', 'width': args.width, 'height': args.height,
                          'mock_requests': len(server.calls), 'invalid_requests': server.invalid, 'credentials_forwarded': False}))
        return 0
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


if __name__ == '__main__':
    raise SystemExit(main())
