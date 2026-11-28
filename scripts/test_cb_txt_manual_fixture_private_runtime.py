#!/usr/bin/env python3
"""Exercise the private imported-TXT manual runner against a local service."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import threading

from mock_weread import CB_READING_ID, CHAPTERS, MockServer, QUOTE, chapter_txt, prepare
from txt_coordinates import PlainSource


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True); parser.add_argument('--run-dir', type=Path, required=True)
    parser.add_argument('--width', type=int, default=600); parser.add_argument('--height', type=int, default=800)
    parser.add_argument('--dpi', type=int, default=167); parser.add_argument('--dry', action='store_true')
    args = parser.parse_args(); root, runtime = args.run_dir.resolve(), args.koreader.resolve()
    server = MockServer(0); server.cb_reading = True; server.content_format = 'txt'; thread = None
    source = chapter_txt(1); model = PlainSource(source)
    first = model.locate('这是第1章的第16段。' + QUOTE)[0]; following = first + 1
    server.progress[CB_READING_ID] = dict(chapterUid=1, chapterIdx=1, chapterOffset=first, progress=25, summary='synthetic old summary')
    try:
        prepare(root, runtime, server.server_port, args.width, args.height, args.dpi)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        payload = dict(book=CB_READING_ID, chapter='1', chapter_idx=1, first_offset=first, next_offset=following,
                       expected_summary=model.excerpt(following)['text'], source=source, source_format='web_txt',
                       chapters=CHAPTERS, book_version=0, owner='900000',
                       cookies=dict(wr_vid='900000', wr_skey='synthetic-cookie-session'), armed=not args.dry)
        env = os.environ | dict(WEREAD_FIXTURE_SYNTHETIC='1', WEREAD_FIXTURE_MOCK_PORT=str(server.server_port))
        runner = Path(__file__).resolve().parent / 'run_cb_fixture_manual_ui.py'
        proc = subprocess.run(['python3', str(runner), '--koreader', str(runtime), '--candidate', str(root / 'candidate.zip'),
                               '--width', str(args.width), '--height', str(args.height), '--dpi', str(args.dpi)],
                              input=json.dumps(payload, ensure_ascii=False).encode(), stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, env=env, timeout=780)
        value = json.loads(proc.stdout)
        expected = (dict(result='DRY_RUN', profile_removed=True, installed_bytes_match=True, native_choice=True,
                         write_blocked=True, writes=0, denied=1, credentials_not_persisted=True) if args.dry else
                    dict(result='PASS', profile_removed=True, installed_bytes_match=True, native_choice=True, actual_source=True,
                         upload_confirmed=True, fresh_process=True, pending_cleared=True, journal_cleared=True,
                         automatic_disabled=True, writes=2, denied=0, credentials_not_persisted=True))
        if proc.returncode or value != expected or server.request_totals.get(('/web/book/read',''), 0) != (0 if args.dry else 2):
            raise ValueError('private TXT manual rehearsal failed: ' + json.dumps(value))
        print(json.dumps(dict(result='PASS', dry=args.dry, width=args.width, height=args.height,
                              synthetic_writes=0 if args.dry else 2, private_profile_removed=True)))
    finally:
        if thread is not None: server.shutdown(); thread.join()
        server.server_close()


if __name__ == '__main__': main()
