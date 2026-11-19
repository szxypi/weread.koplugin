#!/usr/bin/env python3
"""Actual KOReader imported-highlight styles against loopback only."""
import argparse
from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import threading
from urllib.parse import urlsplit

from cb_fixture_style_trial import Intent, prepare
from annotation_experiment_model import digest
from highlight_trial_model import observe
from mark_color_model import observe_color
from mark_style_trial_model import observe_change
from mock_weread import CB_READING_ID, CHAPTERS, MockServer
from my_mark_span import project as span_project
from native_trial_pipe import Frames, reply, stop, write_initial
from selection_trial_mock import Opener, credentials
from test_secure_native_session import Backend
from verify_cb_fixture_highlight_native import Observer


class Unconfirmed(ValueError):
    def __init__(self, report):
        self.report = report


class Server(MockServer):
    def __init__(self, case, palette=False):
        super().__init__(0)
        self.cb_reading = self.selection_fixture = self.combined_upload_read = True
        self.selection_marks = {}; self.selection_thoughts = {}; self.case = case; self.palette = palette
        self.progress[CB_READING_ID] = dict(chapterUid=2, chapterIdx=2, chapterOffset=0, progress=0, summary='')

    def route(self, method, target, data):
        parsed = urlsplit(target)
        if parsed.hostname == 'i.weread.qq.com' and method == 'GET' and parsed.path == '/book/getProgress':
            from urllib.parse import parse_qs
            if parse_qs(parsed.query) != {'bookId': [CB_READING_ID]}: raise ValueError('synthetic scope')
            return 200, self.get_progress(CB_READING_ID)
        if parsed.hostname == 'i.weread.qq.com' and method == 'POST' and parsed.path == '/book/updateBookmark':
            value = data.get('colorStyle' if self.palette else 'style')
            self.control['selection_thought_mode'] = 'no_change' if self.case == 'no-' + str(value) else 'plain'
        return super().route(method, target, data)


def run_ui(command, payload, plan, body, baseline, intent, read, *, armed, palette=False):
    if intent.read() != (None, None) or read() != baseline: raise ValueError('cb_style/preflight')
    value = dict(payload, styles=not palette, palette=palette, armed=armed, token=secrets.token_hex(16))
    receipt = intent.reserve(plan) if armed else None
    child = None; steps = 0; target = row = None
    try:
        child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
        write_initial(child.stdin, value); frames = Frames(child.stdout, value['token'], timeout=360)
        while True:
            kind, event = frames.next()
            if kind == 'RESULT': result = event; break
            if not armed:
                if steps or event != {'seq': 0, 'preview': body} or read() != baseline: raise ValueError('cb_style/dry')
                reply(child.stdin, {'seq': 0, 'ok': True}); steps = 1; continue
            state, owned = intent.read(); seq = event.get('seq')
            if (state is None or owned != receipt or state['plan'] != plan or set(event) != {'seq', 'created_id'}
                    or type(seq) is not int or seq != steps + 1 or seq not in (1, 2, 3, 4)):
                raise ValueError('cb_style/step')
            expected_phase = {1: 'create_pending', 2: 'straight_pending', 3: 'wave_pending', 4: 'delete_pending'}[seq]
            if state['phase'] != expected_phase or target is not None and state['target'] != target:
                raise ValueError('cb_style/intent')
            current = read()
            if seq == 1:
                target = observe(baseline, current, body); row = current['marks']['updated'][target['id']]
            elif seq in (2, 3):
                target, row = (observe_color(baseline, current, body, target, row, {2: 0, 3: 3}[seq]) if palette
                               else observe_change(baseline, current, body, target, row, {2: 0, 3: 2}[seq]))
            else:
                observe(baseline, current, dict(body, style=1 if palette else 2), deleted=True, target=target)
            if event['created_id'] != target['id']: raise ValueError('cb_style/target')
            if seq < 4:
                receipt = intent.advance(receipt, {1: 'created', 2: 'straight', 3: 'wave'}[seq], target=target)
                if observe(baseline, read(), dict(body, style=row['style'], colorStyle=row['colorStyle']), target=target) != target:
                    raise ValueError('cb_style/changed')
                receipt = intent.advance(receipt, {1: 'straight_pending', 2: 'wave_pending', 3: 'delete_pending'}[seq])
            steps = seq; reply(child.stdin, dict(seq=seq, ok=True, created_id=event['created_id']))
        status = child.wait(timeout=15)
        if status and result.get('result') == 'UNVERIFIED': raise Unconfirmed(result)
        if status: raise ValueError('cb_style/child')
        expected = dict(result='PASS' if armed else 'DRY_RUN', profile_removed=True, installed_bytes_match=True,
                        stage=None, native_controls=True, writes=4 if armed else 0, fresh_offline=armed,
                        credentials_not_persisted=True)
        if result != expected or steps != (4 if armed else 1): raise ValueError('cb_style/result')
        if armed:
            observe(baseline, read(), dict(body, style=1 if palette else 2), deleted=True, target=target)
            receipt = intent.advance(receipt, 'verified'); intent.finish(receipt)
        elif read() != baseline: raise ValueError('cb_style/changed')
        return result
    finally:
        if child is not None: stop(child)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True); parser.add_argument('--run-dir', type=Path, required=True)
    parser.add_argument('--width', type=int, default=600); parser.add_argument('--height', type=int, default=800)
    parser.add_argument('--dpi', type=int, default=167); parser.add_argument('--case', choices=('normal', 'no-0', 'no-2', 'no-3', 'orchestrated'), default='normal')
    parser.add_argument('--production', action='store_true')
    parser.add_argument('--palette', action='store_true')
    args = parser.parse_args(); root = args.run_dir.resolve(); root.mkdir(parents=True, exist_ok=False)
    if args.palette and (args.production or args.case in ('no-2', 'orchestrated')) or not args.palette and args.case == 'no-3':
        raise ValueError('synthetic scope')
    candidate = root / 'candidate.zip'; subprocess.run(['bash', 'scripts/package_release.sh', str(candidate)], check=True, capture_output=True)
    profiles = set(Path('/dev/shm').glob('weread-cb-highlight-*'))
    server = Server(args.case, args.palette); thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
    try:
        grant = credentials(); intent = Intent(Backend()); observer = Observer(CB_READING_ID, grant, lambda: True, intent, opener=Opener(server))
        baseline = observer.observe(grant); raw = server.chapter_source(2)
        sample = dict(book_id=CB_READING_ID, chapter_uid='2', chapters=CHAPTERS, source_format='web_xhtml', source=raw,
                      source_raw_sha256=hashlib.sha256(raw.encode()).hexdigest())
        plan, body = prepare('900000', CB_READING_ID, 'a' * 32, sample, 700, baseline)
        if args.palette: body = dict(body, colorStyle=3); plan = dict(plan, request_sha256=digest(body))
        span = span_project(raw, CB_READING_ID, '2', dict(type=1, chapterUid=2, range=body['range'], markText=body['markText']))
        payload = dict(book=CB_READING_ID, chapter='2', chapter_idx=2, source=raw, chapters=CHAPTERS,
                       cookies={'wr_vid': '900000', 'wr_skey': 'mock_key'}, native=grant, owner='900000', book_version=700,
                       body=body, first=span['first'], last=span['last'])
        os.environ.update(WEREAD_FIXTURE_SYNTHETIC='1', WEREAD_FIXTURE_MOCK_PORT=str(server.server_port))
        command = ['python3', 'scripts/run_cb_fixture_highlight_ui.py', '--koreader', str(args.koreader), '--candidate', str(candidate),
                   '--width', str(args.width), '--height', str(args.height), '--dpi', str(args.dpi)]
        if args.case == 'orchestrated':
            from unittest.mock import patch
            from verify_cb_fixture_style_native import run
            receipt = object()
            class Journal:
                imported = False
                def read(self):
                    return (dict(phase='imported', target=CB_READING_ID, attempt='a'*32, plan={'owner':'900000'}), receipt) if self.imported else (None, None)
            class NativeStore:
                def load(self, _owner): return grant
            class Source:
                def __init__(self): self.samples=[]; self.last_checks=dict(catalog_unchanged=True, versions_unchanged=True, position_unchanged=True)
                def set_cookie(self, *_args): pass
                def verify_account(self): pass
                def close(self): pass
                def inspect(self, book):
                    assert book == CB_READING_ID
                    return dict(deepcopy(sample), baseline={'chapter':'0', 'offset':0, 'percent':0})
            journal = Journal()
            def uploader(_probe, _journal, _grant, _check, source, *, apply, cleanup_gate):
                assert apply; journal.imported=True; assert source(CB_READING_ID)
                cleaned=cleanup_gate(journal, receipt, {}, CB_READING_ID)
                if cleaned: journal.imported=False
                return {'result':'EPUB_IMPORT_AND_SOURCE_VERIFIED' if cleaned else 'UNVERIFIED', 'phase':'restored' if cleaned else 'imported'}
            with patch('verify_cb_fixture_highlight_native.save_refreshed_web_session', return_value=False):
                result=run(dict(vid='900000',cookies={'wr_vid':'900000','wr_skey':'mock_key'}),None,NativeStore(),grant,journal,intent,
                           command,apply=True,uploader=uploader,upload_factory=lambda *_:None,source_factory=Source,
                           observer_factory=lambda book,creds,authority,store:Observer(book,creds,authority,store,opener=Opener(server)))
            assert result['result']=='CB_NATIVE_STYLE_VERIFIED' and result['native_writes']==4 and not journal.imported
            assert server.highlight_posts==4 and intent.read()==(None,None)
            print(json.dumps(dict(result='PASS',case=args.case,width=args.width,height=args.height,mock_writes=4,no_replay=True)))
            return
        read = lambda: observer.observe(grant)
        def invoke(armed):
            if args.production:
                from verify_cb_fixture_style_native import run_ui as production_run
                return production_run(command, payload, plan, body, baseline, intent, lambda: True, read, armed=armed)
            return run_ui(command, payload, plan, body, baseline, intent, read, armed=armed, palette=args.palette)
        dry = invoke(False)
        assert dry['result'] == 'DRY_RUN' and server.highlight_posts == 0
        if args.case == 'normal':
            live = invoke(True)
            assert live['result'] == 'PASS' and server.highlight_posts == 4 and not server.selection_marks
            assert intent.read() == (None, None)
        else:
            try: invoke(True)
            except Unconfirmed as error:
                assert error.report.get('stage') == dict(result='UNCONFIRMED', phase=('color' if args.palette else 'style') + args.case[-1],
                                                         retained_pending=True, no_retry=True)
            except ValueError:
                if not args.production: raise
            else: raise AssertionError('unconfirmed update accepted')
            state, _ = intent.read()
            assert state and state['phase'] == ('straight_pending' if args.case == 'no-0' else 'wave_pending')
            assert server.highlight_posts == (2 if args.case == 'no-0' else 3)
            before = server.highlight_posts
            try: invoke(True)
            except ValueError: pass
            else: raise AssertionError('pending write replayed')
            assert server.highlight_posts == before
        print(json.dumps(dict(result='PASS', case=args.case, width=args.width, height=args.height,
                              dry_blocked=True, mock_writes=server.highlight_posts, no_replay=True)))
    finally:
        server.shutdown(); thread.join(); server.server_close()
        assert set(Path('/dev/shm').glob('weread-cb-highlight-*')) == profiles, 'native fixture profile leaked'


if __name__ == '__main__': main()
