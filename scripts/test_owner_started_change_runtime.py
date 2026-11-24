#!/usr/bin/env python3
"""Loopback-only end-to-end test of the guarded owner native UI runner."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import socket
import subprocess
import sys
import threading
from urllib.parse import parse_qs, urlsplit

from run_owner_reading_state_change_ui import FRAME
from test_owner_reading_state_change_ui import payload, point, shelf
from verify_owner_started_change_preview import decode_runner


class Server(ThreadingHTTPServer):
    def __init__(self):
        super().__init__(('127.0.0.1', 0), Handler)
        self.flag = 0;self.posts = [];self.gets = 0;self.denied = 0;self.mode = 'normal'

    def __enter__(self):
        self.thread = threading.Thread(target=self.serve_forever, daemon=True);self.thread.start();return self

    def __exit__(self, *_):
        self.shutdown();self.server_close();self.thread.join()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass

    def do_GET(self): self.dispatch(False)
    def do_POST(self): self.dispatch(True)

    def dispatch(self, post):
        server = self.server
        query = parse_qs(urlsplit(self.path).query)
        target = query.get('url', [''])[0]
        path = urlsplit(target)
        try:
            if urlsplit(self.path).path != '/__proxy' or path.netloc != 'i.weread.qq.com' or path.scheme != 'https':
                raise ValueError('route')
            if not post and path.path == '/shelf/sync' and not path.query:
                value = shelf();server.gets += 1
            elif not post and path.path == '/book/getProgress' and parse_qs(path.query) == {'bookId': ['41']}:
                value = point();value['book']['isStartReading'] = server.flag
                value['book']['startReadingTime'] = 123 if server.flag else 0;server.gets += 1
            elif post and path.path == '/book/markstatus' and not path.query:
                size = int(self.headers.get('Content-Length', 0));assert 1 <= size <= 1024
                body = json.loads(self.rfile.read(size))
                if (set(body) != {'auto', 'bookId', 'finishInfo', 'isCancel', 'status'} or body['bookId'] != '41'
                        or body['auto'] != 0 or body['finishInfo'] != 0 or body['status'] != 2 or body['isCancel'] not in (0, 1)):
                    raise ValueError('body')
                server.posts.append(body['isCancel'])
                if server.mode != 'no_change': server.flag = int(body['isCancel'] == 0)
                if server.mode == 'lost':
                    self.connection.shutdown(socket.SHUT_RDWR);self.connection.close();return
                value = {'status': 1}
            else: raise ValueError('route')
            raw = json.dumps(value).encode();self.send_response(200);self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(raw)));self.end_headers();self.wfile.write(raw)
        except Exception:
            server.denied += 1;self.send_error(403)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', required=True, type=Path)
    parser.add_argument('--width', type=int, default=600);parser.add_argument('--height', type=int, default=800)
    parser.add_argument('--dpi', type=int, default=167);args = parser.parse_args()
    report = {'result': 'UNVERIFIED'}
    try:
        with Server() as server:
            port = server.server_address[1]
            def invoke(desired, armed, mode='normal'):
                server.mode = mode
                value = payload(armed);value['mock_port'] = port;value['desired'] = desired
                value['progress']['book']['isStartReading'] = server.flag
                value['progress']['book']['startReadingTime'] = 123 if server.flag else 0
                command = [sys.executable, str(Path(__file__).with_name('run_owner_reading_state_change_ui.py')),
                           '--koreader', str(args.koreader), '--width', str(args.width), '--height', str(args.height),
                           '--dpi', str(args.dpi), '--mock-port', str(port)]
                if armed: command.append('--armed')
                return subprocess.run(command, input=json.dumps(value).encode(), capture_output=True, timeout=180)
            dry = invoke(True, False);decode_runner(dry.stdout, dry.returncode)
            for desired, mode in ((True, 'normal'), (False, 'normal'), (True, 'lost'), (False, 'normal')):
                child = invoke(desired, True, mode);decode_runner(child.stdout, child.returncode, armed=True)
                assert server.flag == int(desired)
            failed = invoke(True, True, 'no_change')
            assert failed.returncode and failed.stdout.count(FRAME) == 1
            result = json.loads(failed.stdout.split(FRAME)[1])
            assert result['result'] == 'UNVERIFIED' and result.get('phase') == 'commit' and result['profile_removed']
            assert server.flag == 0 and server.posts == [0, 1, 0, 1, 0] and server.denied == 0
            report = dict(result='PASS', dry_run_posts=0, synthetic_posts=len(server.posts), lost_receipt_checked=True,
                          unchanged_result_rejected=True, denied=server.denied, external_account_writes=0)
    except Exception:
        pass
    print(json.dumps(report));return int(report['result'] != 'PASS')


if __name__ == '__main__':
    raise SystemExit(main())
