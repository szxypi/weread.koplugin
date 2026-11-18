#!/usr/bin/env python3
"""Run packaged KOReader's first-CB sync against a synthetic local service."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import threading
from urllib.parse import parse_qs, urlsplit

from mock_weread import MockServer, prepare

REPO = Path(__file__).resolve().parent.parent
BOOK = 'CB_SyntheticResume'


class FirstServer(MockServer):
    def __init__(self, mode):
        super().__init__(0); self.cb_reading = True; self.mode = mode; self.first_posts = 0; self.delayed_reads = 0
        self.progress[BOOK] = dict(chapterUid=0, chapterIdx=0, chapterOffset=0, progress=0, summary='')

    def route(self, method, target, data):
        url = urlsplit(target)
        if url.hostname == 'i.weread.qq.com' and url.path == '/book/getProgress' and method == 'GET':
            if parse_qs(url.query) != {'bookId': [BOOK]}: raise ValueError('first fixture scope')
            value = self.get_progress(BOOK)
            value['book'].update(readingTime=1 if self.mode == 'native_time' else 0, recordReadingTime=0, ttsTime=0)
            return 200, value
        if (url.hostname == 'weread.qq.com' and url.path == '/web/book/getProgress' and method == 'GET'
                and self.mode == 'delayed' and self.first_posts and self.delayed_reads == 0):
            self.delayed_reads += 1
            value = self.get_progress(BOOK); value['book']['chapterOffset'] += 1
            return 200, value
        if url.hostname == 'weread.qq.com' and url.path == '/web/book/read' and method == 'POST':
            if self.first_posts or 'rt' in data or 'ts' in data or 'rn' in data or 'sg' in data:
                raise ValueError('first fixture write limit')
            self.first_posts += 1
            if self.mode == 'noack_unapplied': return 200, {}
            status, value = super().route(method, target, data)
            return status, {} if self.mode == 'noack' else value
        return super().route(method, target, data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True); parser.add_argument('--run-dir', type=Path, required=True)
    parser.add_argument('--width', type=int, default=600); parser.add_argument('--height', type=int, default=800)
    parser.add_argument('--dpi', type=int, default=167)
    parser.add_argument('--format', choices=('epub', 'txt'), default='epub')
    parser.add_argument('--mode', choices=('normal', 'noack', 'noack_unapplied', 'changed', 'save_failed', 'verify_save_failed',
                                           'delayed', 'native_time', 'no_native'), default='normal')
    args = parser.parse_args(); root, runtime = args.run_dir.resolve(), args.koreader.resolve()
    server = FirstServer(args.mode); server.content_format = args.format; thread = None
    try:
        prepare(root, runtime, server.server_port, args.width, args.height, args.dpi)
        (root / 'xdg').mkdir(mode=0o700); server.log_path = root / 'evidence/requests.jsonl'
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        environment = os.environ | dict(KO_HOME=str(root / 'profile'), XDG_RUNTIME_DIR=str(root / 'xdg'),
            WEREAD_CB_FIRST_MODE=args.mode, WEREAD_CB_FIRST_FORMAT=args.format, EMULATE_READER='1', EMULATE_READER_W=str(args.width),
            EMULATE_READER_H=str(args.height), EMULATE_READER_DPI=str(args.dpi), EMULATE_BW_SCREEN='1', EMULATE_BB_TYPE='BB8')
        probe = REPO / 'spec/koreader/cb_initial_ui_smoke.lua'; log = root / 'evidence/runtime.log'
        with log.open('w') as output:
            result = subprocess.run(['./luajit', str(probe)], cwd=runtime, env=environment,
                                    stdout=output, stderr=subprocess.STDOUT, timeout=150)
        if result.returncode: raise ValueError('first UI failed; inspect synthetic runtime log')
        raw = log.read_bytes(); marker = b'\nWEREAD_CB_FIRST_UI='
        if raw.count(marker) != 1 or b'[WeRead] forceRePaint failed:' in raw: raise ValueError('first UI result')
        value = json.loads(raw.split(marker, 1)[1].splitlines()[0])
        success = args.mode in ('normal', 'delayed')
        blocked = args.mode in ('changed', 'native_time', 'no_native')
        expected = dict(result='PASS', mode=args.mode, cancelled=True, explicit_choice=True, verified=success,
                        journal_pending=not success and not blocked, pending=not success and args.mode != 'verify_save_failed')
        if value != expected or server.first_posts != (0 if blocked else 1): raise ValueError('first UI mismatch')
        server.shutdown(); thread.join(); thread = None
        if not blocked:
            with (root / 'evidence/reopen.log').open('w') as output:
                reopened = subprocess.run(['./luajit', str(probe)], cwd=runtime,
                    env=environment | {'WEREAD_CB_FIRST_REOPEN': '1'}, stdout=output, stderr=subprocess.STDOUT, timeout=120)
            raw = (root / 'evidence/reopen.log').read_bytes(); marker = b'\nWEREAD_CB_FIRST_REOPEN='
            if reopened.returncode or raw.count(marker) != 1: raise ValueError('first offline reopen failed')
            value = json.loads(raw.split(marker, 1)[1].splitlines()[0])
            if value != dict(result='PASS', offline=True, requests=0, journal_pending=not success):
                raise ValueError('first offline reopen mismatch')
        print(json.dumps(dict(result='PASS', mode=args.mode, source_format=args.format, width=args.width, height=args.height,
                              first_requests=server.first_posts, offline_reopen=not blocked)))
    finally:
        if thread is not None: server.shutdown(); thread.join()
        server.server_close()


if __name__ == '__main__': main()
