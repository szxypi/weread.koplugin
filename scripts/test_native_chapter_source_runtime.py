#!/usr/bin/env python3
"""Exercise native chapter HTTP transport in KOReader against a local fixture."""
import argparse
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
from urllib.parse import parse_qs, urlsplit

from test_native_chapter_package import ENCRYPTED

REPO = Path(__file__).resolve().parent.parent
FRAME = b'\nWEREAD_NATIVE_SOURCE_RESULT='


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        self.dispatch()

    def do_POST(self):
        self.dispatch()

    def dispatch(self):
        server = self.server
        server.leaked |= any(key.lower() in ('vid', 'accesstoken', 'cookie') for key in self.headers)
        outer = urlsplit(self.path)
        query = parse_qs(outer.query)
        target = urlsplit(query.get('url', [''])[0])
        server.paths.append(target.path)
        code, headers, body = 200, {}, None
        if target.hostname != 'i.weread.qq.com':
            code, body = 400, b''
        elif target.path == '/book/info' and self.command == 'GET':
            body = json.dumps(dict(bookId='42', format='epub', version=1)).encode()
        elif target.path == '/book/chapterInfos' and self.command == 'POST':
            incoming = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
            server.catalog_valid &= incoming == dict(bookIds=['42'], synckeys=[0], updateTimes=[0], maxfreeIdx=[0])
            row = dict(chapterUid=37, wordCount=250, price=10 if server.mode == 'paid' else 0)
            body = json.dumps({'errcode': -2014} if server.mode == 'catalog_rejected'
                              else {'data': [dict(bookId='42', updated=[row])]}).encode()
        elif target.path == '/book/chapterdownload' and self.command == 'GET':
            fields = parse_qs(target.query, keep_blank_values=True)
            server.download_valid &= (fields.get('bookId') == ['42'] and fields.get('chapters') == ['0,37']
                                      and fields.get('stopAutoPayWhenBNE') == ['1'] and fields.get('preview') == ['0'])
            if server.mode == 'rate':
                code, body = 429, b'{}'
            elif server.mode == 'auth':
                code, body = 401, b'{}'
            elif server.mode in ('rate_json', 'auth_json', 'denied_json'):
                errcode = {'rate_json': -2014, 'auth_json': -2012, 'denied_json': -2041}[server.mode]
                body = json.dumps({'errcode': errcode}).encode()
            else:
                body = b'corrupt package' if server.mode == 'corrupt' else base64.b64decode(ENCRYPTED)
                if server.mode != 'missing_header':
                    headers['encryptkey'] = 'vwSvXMONEDngLYTAXw3olg=='
        else:
            code, body = 400, b''
        self.send_response(code)
        for key, value in headers.items():
            self.send_header(key, value)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def run(runtime):
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    endpoint = 'http://127.0.0.1:' + str(server.server_port)
    try:
        with tempfile.TemporaryDirectory(prefix='weread-native-source-', dir='/dev/shm') as root:
            xdg = Path(root) / 'xdg'
            xdg.mkdir(mode=0o700)
            env = dict(os.environ, KO_HOME=root, XDG_RUNTIME_DIR=str(xdg), LD_LIBRARY_PATH=str(runtime / 'libs'),
                       SDL_VIDEODRIVER='dummy', EMULATE_READER='1', WEREAD_SYNTHETIC='1')
            payload = dict(credentials=dict(vid='12345678', accessToken='synthetic-access',
                                            refreshToken='synthetic-refresh', deviceId='eink334691225' + '0'*19),
                           book_id='42', uid='37', mock_endpoint=endpoint)
            for mode, reason, count in (('ok', None, 3), ('paid', 'not_entitled', 2), ('rate', 'rate_limited', 3),
                                        ('auth', 'auth_expired', 3), ('missing_header', 'unavailable', 3),
                                        ('corrupt', 'unavailable', 3), ('rate_json', 'rate_limited', 3),
                                        ('auth_json', 'auth_expired', 3), ('denied_json', 'service_rejected', 3),
                                        ('catalog_rejected', 'service_rejected', 2)):
                server.mode, server.paths, server.leaked = mode, [], False
                server.catalog_valid, server.download_valid = True, True
                process = subprocess.run([str(runtime/'luajit'), str(REPO/'spec/koreader/native_chapter_source_probe.lua'),
                                          str(REPO)], cwd=runtime, env=env, input=json.dumps(payload).encode(),
                                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
                if process.stdout.count(FRAME) != 1:
                    raise AssertionError(mode + ': probe output')
                value = json.loads(process.stdout.split(FRAME, 1)[1])
                assert len(server.paths) == count and value['requests'] == count, mode
                assert not server.leaked and server.catalog_valid and server.download_valid, mode
                if reason is None:
                    assert process.returncode == 0 and value['ok'], mode
                    assert value['body_sha256'] == hashlib.sha256(b'<p>Synthetic</p>').hexdigest(), mode
                    assert value['web_coordinate_authority'] is False, mode
                else:
                    assert process.returncode != 0 and value == dict(ok=False, requests=count, reason=reason), mode
        print('PASS: native KOReader HTTP, entitlement, rate limit, authorization and bad package')
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    run(parser.parse_args().koreader.resolve())


if __name__ == '__main__':
    main()
