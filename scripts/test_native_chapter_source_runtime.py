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

from test_native_chapter_package import ENCRYPTED, archive

REPO = Path(__file__).resolve().parent.parent
FRAME = b'\nWEREAD_NATIVE_SOURCE_RESULT='
PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip5sAAAAASUVORK5CYII=')
READING_BODY = ('<html><body><img src="../images/cover.png"/>'
                + ''.join(f'<p>Native source integrated marker {i} synthetic text.</p>' for i in range(1,81))
                + '</body></html>').encode()
READING_PACKAGE = archive([('text/37.html', READING_BODY), ('style/book.css', 'p{background:url(../images/cover.png)}'),
                           ('images/cover.png', PNG)])
REMOTE_URL = 'https://img.qq.com/image.png?a=1&b=2'
REMOTE_BODY = READING_BODY.replace(b'../images/cover.png', b'https://img.qq.com/image.png?a=1&amp;b=2')
REMOTE_PACKAGE = archive([('text/37.html', REMOTE_BODY),
                          ('style/book.css', 'p{background:url("' + REMOTE_URL + '")}')])
REMOTE_ZERO_CSS_PACKAGE = archive([('text/37.html', REMOTE_BODY),
    ('style/book.css', 'html,body{font-size:0;color:black}.hidden{font-size:0}'
                       'p{background:url("' + REMOTE_URL + '")}')])
REMOTE_MULTI_BODY = REMOTE_BODY.replace(b'<html><body>',
    b'<html><head><link rel="stylesheet" href="../style/b.css"/>'
    b'<link rel="stylesheet" href="../style/a.css"/></head><body>', 1)
REMOTE_MULTI_CSS_PACKAGE = archive([('text/37.html', REMOTE_MULTI_BODY),
    ('style/a.css', 'p{color:black}p{background:url("' + REMOTE_URL + '")}'),
    ('style/b.css', 'p{color:blue}')])


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
        if target.hostname == 'img.qq.com' and target.path == '/image.png' and self.command == 'GET':
            server.download_valid &= parse_qs(target.query) == {'a': ['1'], 'b': ['2']}
            if server.mode == 'remote_rate':
                code, body = 429, b'{}'
            elif server.mode == 'remote_redirect':
                code, body = 302, b''
                headers['location'] = 'https://other.invalid/'
            elif server.mode == 'remote_invalid':
                body = b'not an image'
            else:
                body = PNG
        elif target.hostname != 'i.weread.qq.com':
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
                body = (b'corrupt package' if server.mode == 'corrupt' else READING_PACKAGE if server.mode == 'read'
                        else REMOTE_ZERO_CSS_PACKAGE if server.mode == 'remote_zero_css'
                        else REMOTE_MULTI_CSS_PACKAGE if server.mode == 'remote_multi_css'
                        else REMOTE_PACKAGE if server.mode.startswith('remote')
                        else base64.b64decode(ENCRYPTED))
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
                       SDL_VIDEODRIVER='dummy', EMULATE_READER='1', WEREAD_SYNTHETIC='1',
                       WEREAD_OWNER_NATIVE_IMAGE_TMPFS='1')
            payload = dict(credentials=dict(vid='12345678', accessToken='synthetic-access',
                                            refreshToken='synthetic-refresh', deviceId='eink334691225' + '0'*19),
                           book_id='42', uid='37', mock_endpoint=endpoint, prepare=True)
            for mode, reason, count in (('ok', None, 3), ('read', None, 3), ('remote', None, 4), ('remote_owner', None, 4),
                                        ('remote_rate', 'rate_limited', 4), ('remote_redirect', 'unavailable', 4),
                                        ('remote_invalid', 'invalid_image', 4), ('paid', 'not_entitled', 2), ('rate', 'rate_limited', 3),
                                        ('auth', 'auth_expired', 3), ('missing_header', 'unavailable', 3),
                                        ('corrupt', 'unavailable', 3), ('rate_json', 'rate_limited', 3),
                                        ('auth_json', 'auth_expired', 3), ('denied_json', 'service_rejected', 3),
                                        ('catalog_rejected', 'service_rejected', 2)):
                server.mode, server.paths, server.leaked = mode, [], False
                server.catalog_valid, server.download_valid = True, True
                payload['render'] = mode in ('read', 'remote')
                payload['fetch_remote'] = mode.startswith('remote')
                payload['owner_render'] = mode == 'remote_owner'
                payload['search_token'] = 'integrated' if mode == 'remote_owner' else None
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
                    expected_body = REMOTE_BODY if mode in ('remote', 'remote_owner') else READING_BODY if mode == 'read' else b'<p>Synthetic</p>'
                    assert value['body_sha256'] == hashlib.sha256(expected_body).hexdigest(), mode
                    assert value['web_coordinate_authority'] is False, mode
                    if mode == 'remote':
                        assert value['resources'] == dict(ok=True, localized=2, remote=0, downloaded=1,
                                                          web_coordinate_authority=False, rendered=True), mode
                    elif mode == 'remote_owner':
                        assert value['resources'] == dict(ok=True, localized=2, remote=0, downloaded=1,
                                                          web_coordinate_authority=False, owner_rendered=True), mode
                        offline = subprocess.run([str(runtime/'luajit'), str(REPO/'spec/koreader/native_chapter_owner_offline_probe.lua'),
                                                  str(REPO)], cwd=runtime, env=env, stdout=subprocess.PIPE,
                                                 stderr=subprocess.PIPE, timeout=60)
                        marker = b'\nWEREAD_NATIVE_OFFLINE_RESULT='
                        assert offline.returncode == 0 and offline.stdout.count(marker) == 1, mode
                        assert json.loads(offline.stdout.split(marker, 1)[1]) == dict(ok=True, offline_network=0,
                                                                                   assets=1, web_coordinate_authority=False), mode
                    elif mode == 'read':
                        assert value['resources'] == dict(ok=True, localized=2, remote=0,
                                                          web_coordinate_authority=False, rendered=True), mode
                    else:
                        assert value['resources'] == dict(ok=True, localized=0, remote=0, web_coordinate_authority=False), mode
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
