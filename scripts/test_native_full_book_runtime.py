#!/usr/bin/env python3
"""Exercise mixed-source full-book download and resume in real KOReader."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import tarfile
import threading
from urllib.parse import parse_qs, urlsplit

from test_native_chapter_package import archive
from test_native_chapter_source_runtime import PNG, REMOTE_URL

REPO = Path(__file__).resolve().parent.parent


def body(uid):
    image = '<img src="https://img.qq.com/image.png?a=1&amp;b=2"/>' if uid != '39' else ''
    return '<html><body>' + image + f'<p>Full chapter {uid} native marker readable text.</p></body></html>'


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
        target = urlsplit(parse_qs(urlsplit(self.path).query).get('url', [''])[0])
        code, headers, data = 200, {}, None
        if target.hostname == 'img.qq.com' and target.path == '/image.png' and self.command == 'GET':
            server.image_requests += 1
            data = PNG
        elif target.hostname == 'weread.qq.com' and target.path == '/synthetic/resources.tar' and self.command == 'GET':
            server.tar_requests += 1
            data = server.tar_data
        elif target.hostname == 'i.weread.qq.com' and target.path == '/book/info' and self.command == 'GET':
            data = json.dumps(dict(bookId='42', format='epub', version=1)).encode()
        elif target.hostname == 'i.weread.qq.com' and target.path == '/book/chapterInfos' and self.command == 'POST':
            incoming = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
            server.valid &= incoming == dict(bookIds=['42'], synckeys=[0], updateTimes=[0], maxfreeIdx=[0])
            rows = [dict(chapterUid=int(uid), wordCount=250, price=0) for uid in ('37', '38', '39')]
            data = json.dumps({'data': [dict(bookId='42', updated=rows)]}).encode()
        elif target.hostname == 'i.weread.qq.com' and target.path == '/book/chapterdownload' and self.command == 'GET':
            query = parse_qs(target.query, keep_blank_values=True)
            uid = query.get('chapters', [''])[0].removeprefix('0,')
            server.valid &= (uid in ('37', '38', '39') and query.get('bookId') == ['42']
                             and query.get('stopAutoPayWhenBNE') == ['1'] and query.get('preview') == ['0'])
            server.chapters.append(uid)
            if server.expired and uid == '38':
                code, data = 401, b'{}'
            elif server.resume and uid == '38' and not server.resume_marker.exists():
                code, data = 429, b'{}'
            elif uid in ('37', '38', '39'):
                color = 'black' if uid == '37' else 'gray'
                css = ('html,body{font-size:0}' if uid == '37' else '') + f'p{{color:{color}}}'
                if uid != '39':
                    css += 'p{background:url("' + REMOTE_URL + '")}'
                data = archive([(f'text/{uid}.html', body(uid)), ('style/book.css', css)])
                headers['encryptkey'] = 'vwSvXMONEDngLYTAXw3olg=='
            else:
                code, data = 400, b''
        else:
            code, data = 400, b''
        self.send_response(code)
        for key, value in headers.items():
            self.send_header(key, value)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def run(runtime):
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode='w') as archive_file:
        entry = tarfile.TarInfo('fixture.png');entry.size=len(PNG)
        archive_file.addfile(entry, io.BytesIO(PNG))
    server.tar_data=buffer.getvalue()
    thread = threading.Thread(target=server.serve_forever, daemon=True);thread.start()
    try:
        for width, height, dpi, resume, expired, corrupt, switch, web_asset in ((600, 800, 167, False, False, False, False, True),
                                                                      (1264, 1680, 300, True, False, False, False, True),
                                                                      (1264, 1680, 300, True, False, True, False, False),
                                                                      (600, 800, 167, False, True, False, False, False),
                                                                      (600, 800, 167, False, False, False, True, False)):
            with tempfile.TemporaryDirectory(prefix='weread-native-full-', dir='/dev/shm') as root:
                xdg = Path(root) / 'xdg';xdg.mkdir(mode=0o700)
                env = dict(os.environ, KO_HOME=root, XDG_RUNTIME_DIR=str(xdg),
                           LD_LIBRARY_PATH=str(runtime / 'libs'), SDL_VIDEODRIVER='dummy',
                           EMULATE_READER='1', EMULATE_BW_SCREEN='1', EMULATE_BB_TYPE='BB8',
                           EMULATE_READER_W=str(width), EMULATE_READER_H=str(height),
                           EMULATE_READER_DPI=str(dpi), WEREAD_SYNTHETIC='1')
                payload = dict(credentials=dict(vid='12345678', accessToken='synthetic-access',
                               refreshToken='synthetic-refresh', deviceId='eink334691225' + '0' * 19),
                               mock_endpoint='http://127.0.0.1:' + str(server.server_port),
                               resume=resume, expired=expired, corrupt=corrupt, switch=switch, web_asset=web_asset)
                server.resume, server.expired, server.resume_marker, server.chapters = resume, expired, Path(root) / 'resume', []
                server.valid, server.leaked, server.image_requests, server.tar_requests = True, False, 0, 0
                child = subprocess.run([str(runtime/'luajit'), str(REPO/'spec/koreader/native_full_book_probe.lua'), str(REPO)],
                                       input=json.dumps(payload), text=True, env=env, cwd=runtime,
                                       capture_output=True, timeout=150, check=False)
                if child.returncode:
                    raise AssertionError(child.stdout + child.stderr)
                marker='WEREAD_FULL_RESULT='
                line=next(line for line in child.stdout.splitlines() if line.startswith(marker))
                expected = (dict(ok=True,expired=True,chapters=1) if expired else
                            dict(ok=True,switched=True,chapters=3) if switch else
                            dict(ok=True,resumed=resume,chapters=3,styles=2,images=1))
                assert json.loads(line[len(marker):]) == expected
                expected_chapters=(['37','38'] if expired else ['37','38','37','38','39'] if corrupt
                                   else ['37','38','38','39'] if resume else ['37','38','39'])
                assert server.chapters == expected_chapters, server.chapters
                assert server.image_requests==(1 if expired else 3 if corrupt else 2) and server.valid and not server.leaked
                assert server.tar_requests == (1 if web_asset else 0)
        print('PASS: native full book, mixed sources, shared images, rate-limit resume and offline rendering')
    finally:
        server.shutdown();server.server_close();thread.join()


if __name__ == '__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--koreader',type=Path,required=True)
    run(parser.parse_args().koreader.resolve())
