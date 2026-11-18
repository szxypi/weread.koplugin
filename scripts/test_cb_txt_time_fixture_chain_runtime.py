#!/usr/bin/env python3
"""Two-screen TXT time coordinator with KOReader and a synthetic local service."""
import argparse
import copy
import json
import os
from pathlib import Path
import threading
import time

from cb_cloud_position import observed
from cb_fixture_native_time_intent import Intent
from cb_fixture_web_time_evidence import Evidence
from mock_weread import CB_READING_ID, CHAPTERS, MockServer, QUOTE, chapter_txt, prepare
from test_cb_fixture_position_transport import MemoryBackend
from txt_coordinates import PlainSource
from verify_cb_txt_native_time_fixture_ui_trial import time_trial
from verify_readtime_upload import expected_statistics


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True); parser.add_argument('--run-dir', type=Path, required=True)
    args = parser.parse_args(); root, runtime = args.run_dir.resolve(), args.koreader.resolve()
    os.environ['LD_LIBRARY_PATH'] = str(runtime / 'libs')
    server = MockServer(0); server.cb_reading = True; server.content_format = 'txt'; thread = None
    source = chapter_txt(1); model = PlainSource(source)
    first = model.locate('这是第1章的第16段。' + QUOTE)[0]
    plan = dict(book=CB_READING_ID, chapter='1', index=1, first=first, following=first + 1)
    server.progress[CB_READING_ID] = dict(chapterUid=1, chapterIdx=1, chapterOffset=first, progress=25,
                                           summary=model.excerpt(first)['text'])
    now = int(time.time()); base = dict(baseTime=0, readTimes={}, totalReadTime=0, readDays=0)
    try:
        prepare(root, runtime, server.server_port, 600, 800, 167)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        os.environ['WEREAD_FIXTURE_SYNTHETIC'] = '1'; os.environ['WEREAD_FIXTURE_MOCK_PORT'] = str(server.server_port)
        def seconds(): return server.request_totals.get(('/web/book/read', ''), 0) // 3 * 10
        def pair():
            web = server.get_progress(CB_READING_ID)
            web['book'].update(readingTime=seconds(), recordReadingTime=0, ttsTime=0, updateTime=1)
            return copy.deepcopy(web), web
        class Api:
            def progress(self): return pair()[0]
            def stats(self):
                return expected_statistics(base, now, seconds(), time_zone='+08:00') if seconds() else copy.deepcopy(base)
        initial = {channel: observed(raw, CB_READING_ID, CHAPTERS, channel)
                   for channel, raw in zip(('native', 'web'), pair())}
        runner = Path(__file__).resolve().parent / 'run_cb_fixture_manual_ui.py'
        command = ['python3', str(runner), '--koreader', str(runtime), '--candidate', str(root / 'candidate.zip')]
        context = dict(sample=dict(source=source, chapters=CHAPTERS), plan=plan, chapters=CHAPTERS,
                       pair=pair, authority=lambda: True, shelf_current=lambda: True,
                       cookies=lambda: dict(wr_vid='900000', wr_skey='synthetic-cookie-session'), owner='900000',
                       attempt='a' * 32, source_hash='b' * 64, target=CB_READING_ID,
                       initial_observed=initial, attest=lambda: ['first'], command=['first'])
        report = dict(position_writes_known=1, position_writes_uncertain=False)
        intent = Intent(backend=MemoryBackend()); evidences = [Evidence(backend=MemoryBackend()) for _ in range(2)]
        if not time_trial(context, report, intent, evidences, command, Api(), attest=lambda: command): raise ValueError('chain failed')
        if (server.request_totals.get(('/web/book/read', ''), 0) != 6 or report['position_writes_known'] != 7
                or report['position_writes_uncertain'] or len(report['time_stages']) != 2): raise ValueError('chain counts')
        print(json.dumps(dict(result='PASS', blocked_previews=2, time_reports=2, ui_writes=6,
                              screens=2, fresh_offline_reopens=2, private_profiles_removed=True)))
    finally:
        if thread is not None: server.shutdown(); thread.join()
        server.server_close()


if __name__ == '__main__': main()
