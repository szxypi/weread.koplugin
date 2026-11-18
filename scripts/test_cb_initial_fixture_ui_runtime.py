#!/usr/bin/env python3
"""Rehearse the private first-sync fixture runner against a local mock."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import threading

from mock_weread import CHAPTERS, QUOTE, chapter_html, chapter_txt, prepare
from native_reader_fixture import GRANT
from test_cb_initial_ui_runtime import BOOK, FirstServer
from txt_coordinates import PlainSource
from verify_source_coordinates import FilteredSource


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True); parser.add_argument('--run-dir', type=Path, required=True)
    parser.add_argument('--width', type=int, default=600); parser.add_argument('--height', type=int, default=800)
    parser.add_argument('--dpi', type=int, default=167); parser.add_argument('--dry', action='store_true')
    parser.add_argument('--format', choices=('epub', 'txt'), default='epub')
    args = parser.parse_args(); root, runtime = args.run_dir.resolve(), args.koreader.resolve()
    server = FirstServer('normal'); server.content_format = args.format; thread = None
    try:
        prepare(root, runtime, server.server_port, args.width, args.height, args.dpi)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        source = chapter_txt(1) if args.format == 'txt' else chapter_html(1)
        model = PlainSource(source) if args.format == 'txt' else FilteredSource(source)
        offset = model.locate('这是第1章的第16段。' + QUOTE if args.format == 'txt' else '这是第1章的第16段。我们沿着小路慢慢前行')[0]
        summary = model.excerpt(offset)['text'] if args.format == 'txt' else ''.join(c for c in model.anchor_at(offset, size=96) if not c.isspace())[:20]
        payload = dict(book=BOOK, chapter='1', chapter_idx=1, offset=offset, expected_summary=summary,
                       source=source, source_format='web_txt' if args.format == 'txt' else 'web_xhtml', chapters=CHAPTERS, book_version=0, owner=GRANT['vid'], native=GRANT,
                       cookies=dict(wr_vid=GRANT['vid'], wr_skey='synthetic-cookie-session'), armed=not args.dry)
        env = os.environ | dict(WEREAD_FIXTURE_SYNTHETIC='1', WEREAD_FIXTURE_MOCK_PORT=str(server.server_port))
        runner = Path(__file__).resolve().parent / 'run_cb_initial_fixture_ui.py'
        proc = subprocess.run(['python3', str(runner), '--koreader', str(runtime), '--candidate', str(root / 'candidate.zip'),
                               '--width', str(args.width), '--height', str(args.height), '--dpi', str(args.dpi)],
                              input=json.dumps(payload, ensure_ascii=False).encode(), stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, env=env, timeout=420)
        value = json.loads(proc.stdout)
        expected = dict(result='DRY_RUN' if args.dry else 'PASS', profile_removed=True, installed_bytes_match=True,
                        native_choice=True, writes=0 if args.dry else 1, denied=1 if args.dry else 0,
                        fresh_process=not args.dry, credentials_not_persisted=True)
        if proc.returncode or value != expected or server.first_posts != (0 if args.dry else 1):
            raise ValueError('private first-sync rehearsal failed: ' + json.dumps(value))
        print(json.dumps(dict(result='PASS', dry=args.dry, width=args.width, height=args.height,
                              account_data_writes=server.first_posts, private_profile_removed=True)))
    finally:
        if thread is not None: server.shutdown(); thread.join()
        server.server_close()


if __name__ == '__main__': main()
