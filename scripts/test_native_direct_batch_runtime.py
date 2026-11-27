#!/usr/bin/env python3
"""Exercise offline chapter batches through packaged KOReader detail widgets."""
import argparse
import hashlib
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
from urllib.parse import parse_qs, urlsplit

import test_native_full_book_runtime as fixture
from run_persistent_ui_probe import extract_candidate

REPO = Path(__file__).resolve().parent.parent
fixture.body = lambda uid: '<html><body>' + ''.join(
    f'<p>Chapter {uid}, synthetic paragraph {index} for pagination.</p>' for index in range(30)) + '</body></html>'

class Handler(fixture.Handler):
    def dispatch(self):
        target = urlsplit(parse_qs(urlsplit(self.path).query).get('url', [''])[0])
        if (self.server.catalog_faults and self.command == 'GET' and target.hostname == 'i.weread.qq.com'
                and target.path == '/book/info'):
            failure = self.server.catalog_faults.pop(0)
            if failure == 'transport':
                self.close_connection = True
            else:
                self.send_error(failure)
            return
        if (self.server.interrupt_download and self.command == 'GET' and target.hostname == 'i.weread.qq.com'
                and target.path == '/book/chapterdownload' and parse_qs(target.query).get('chapters') == ['0,38']):
            self.server.interrupt_download = False
            self.server.chapters.append('38')
            self.close_connection = True
            return
        if (self.server.hold and self.command == 'GET' and target.path == '/book/chapterdownload'
                and parse_qs(target.query).get('chapters') == ['0,38']):
            self.server.hold_marker.touch()
            self.server.hold_release.wait(20)
            try:
                super().dispatch()
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                self.server.hold_done.set()
            return
        if self.server.locked and self.command == 'POST' and target.hostname == 'i.weread.qq.com' and target.path == '/book/chapterInfos':
            request = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
            self.server.valid &= request == dict(bookIds=['42'], synckeys=[0], updateTimes=[0], maxfreeIdx=[0])
            rows = [dict(chapterUid=int(uid), title=f'Chapter {uid}', level=2 if uid == '38' else 1,
                         wordCount=250, price=1 if uid == '39' else 0)
                    for uid in ('37', '38', '39')]
            data = json.dumps({'data': [dict(bookId='42', updated=rows)]}).encode()
            self.send_response(200)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        super().dispatch()


def run(runtime):
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.catalog_faults = []
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='weread-native-batch-package-', dir='/dev/shm') as package:
            candidate = Path(package)/'candidate.zip'
            subprocess.run(['bash', str(REPO/'scripts/package_release.sh'), str(candidate)], cwd=REPO,
                           check=True, capture_output=True)
            for width, height, dpi in ((600, 800, 167), (1264, 1680, 300)):
                with tempfile.TemporaryDirectory(prefix='weread-native-batch-', dir='/dev/shm') as directory:
                    root = Path(directory)
                    for name in ('plugins', 'xdg'):
                        (root/name).mkdir(mode=0o700)
                    extract_candidate(candidate, root/'plugins')
                    env = dict(os.environ, KO_HOME=str(root), XDG_RUNTIME_DIR=str(root/'xdg'),
                               LD_LIBRARY_PATH=str(runtime/'libs'), SDL_VIDEODRIVER='dummy', EMULATE_READER='1',
                               EMULATE_BW_SCREEN='1', EMULATE_BB_TYPE='BB8', EMULATE_READER_W=str(width),
                               EMULATE_READER_H=str(height), EMULATE_READER_DPI=str(dpi), WEREAD_SYNTHETIC='1')
                    server.resume, server.expired = True, False
                    server.locked = False
                    server.hold = False
                    server.interrupt_download = False
                    server.resume_marker = root/'resume'
                    server.chapters = []
                    server.valid, server.leaked = True, False
                    server.image_requests = server.tar_requests = 0
                    payload = dict(credentials=dict(vid='12345678', accessToken='synthetic-access',
                        refreshToken='synthetic-refresh', deviceId='eink334691225'+'0'*19),
                        mock_endpoint='http://127.0.0.1:'+str(server.server_port))
                    for mode in ('cancel', 'stale', 'fail', 'resume', 'repeat', 'offline', 'catalog_capture'):
                        if mode == 'resume':
                            server.resume_marker.touch()
                        child = subprocess.run([str(runtime/'luajit'), str(REPO/'spec/koreader/native_direct_batch_probe.lua'),
                                                str(REPO)], input=json.dumps(dict(payload, mode=mode)), text=True,
                                               env=env, cwd=runtime, capture_output=True, timeout=150)
                        if child.returncode:
                            raise AssertionError(child.stdout[-6000:] + child.stderr[-6000:])
                        marker = 'WEREAD_DIRECT_BATCH='
                        frames = [line for line in child.stdout.splitlines() if line.startswith(marker)]
                        assert len(frames) == 1
                        expected = dict(ok=True, mode=mode)
                        if mode == 'offline': expected['network_blocked'] = True
                        assert json.loads(frames[0][len(marker):]) == expected
                        expected_chapters = [] if mode in ('cancel', 'stale') else ['37', '38'] if mode == 'fail' else ['37', '38', '38', '39']
                        assert server.chapters == expected_chapters and server.valid and not server.leaked
                    account = hashlib.sha256(b'native-direct-account\0' + b'12345678').hexdigest()
                    book = hashlib.sha256(b'native-direct-book\0' + b'42').hexdigest()
                    marker_path = root/'native-reader-v1'/account/('.native-presence-'+book)
                    assert marker_path.is_file()
                    for mode in ('missing', 'corrupt'):
                        if mode == 'missing': marker_path.unlink()
                        else: marker_path.write_bytes(b'invalid')
                        child = subprocess.run([str(runtime/'luajit'), str(REPO/'spec/koreader/native_direct_batch_probe.lua'),
                                                str(REPO)], input=json.dumps(dict(payload, mode='presence_repair')), text=True,
                                               env=env, cwd=runtime, capture_output=True, timeout=150)
                        if child.returncode: raise AssertionError(child.stdout[-6000:] + child.stderr[-6000:])
                        frames = [line for line in child.stdout.splitlines() if line.startswith('WEREAD_DIRECT_BATCH=')]
                        assert len(frames)==1 and json.loads(frames[0].split('=',1)[1])==dict(
                            ok=True, mode='presence_repair', network_blocked=True)
                        assert marker_path.is_file()
                    pointer = dict(line.split('=', 1) for line in marker_path.read_text().splitlines()[1:])
                    folder = pointer['key'] + ('' if pointer['copy']=='0' else '-'+pointer['copy'])
                    receipt = root/'native-reader-v1'/account/book/folder/'receipt.txt'
                    original_receipt = receipt.read_bytes()
                    receipt.write_bytes(original_receipt+b'corrupt')
                    child = subprocess.run([str(runtime/'luajit'), str(REPO/'spec/koreader/native_direct_batch_probe.lua'),
                                            str(REPO)], input=json.dumps(dict(payload, mode='presence_repair')), text=True,
                                           env=env, cwd=runtime, capture_output=True, timeout=150)
                    if child.returncode: raise AssertionError(child.stdout[-6000:] + child.stderr[-6000:])
                    frames = [line for line in child.stdout.splitlines() if line.startswith('WEREAD_DIRECT_BATCH=')]
                    assert len(frames)==1 and json.loads(frames[0].split('=',1)[1])==dict(
                        ok=True, mode='presence_repair', network_blocked=True)
                    assert marker_path.read_text().splitlines()[1:]!=[f"key={pointer['key']}", f"copy={pointer['copy']}"]
                    assert receipt.read_bytes()==original_receipt+b'corrupt'
                    receipt.write_bytes(original_receipt)
                    marker_path.unlink()
                    child = subprocess.run([str(runtime/'luajit'), str(REPO/'spec/koreader/native_direct_batch_probe.lua'),
                                            str(REPO)], input=json.dumps(dict(payload, mode='presence_unwritable')), text=True,
                                           env=env, cwd=runtime, capture_output=True, timeout=150)
                    if child.returncode: raise AssertionError(child.stdout[-6000:] + child.stderr[-6000:])
                    frames = [line for line in child.stdout.splitlines() if line.startswith('WEREAD_DIRECT_BATCH=')]
                    assert len(frames)==1 and json.loads(frames[0].split('=',1)[1])==dict(
                        ok=True, mode='presence_unwritable', network_blocked=True)
                    pointer = dict(line.split('=', 1) for line in marker_path.read_text().splitlines()[1:])
                    folder = pointer['key'] + ('' if pointer['copy']=='0' else '-'+pointer['copy'])
                    chapter_dir = root/'native-reader-v1'/account/book/folder
                    chapter, = chapter_dir.glob('*.epub')
                    held = chapter.with_suffix('.held')
                    chapter.rename(held)
                    child = subprocess.run([str(runtime/'luajit'), str(REPO/'spec/koreader/native_direct_batch_probe.lua'),
                                            str(REPO)], input=json.dumps(dict(payload, mode='presence_repair', expected_rows=2)), text=True,
                                           env=env, cwd=runtime, capture_output=True, timeout=150)
                    if child.returncode: raise AssertionError(child.stdout[-6000:] + child.stderr[-6000:])
                    frames = [line for line in child.stdout.splitlines() if line.startswith('WEREAD_DIRECT_BATCH=')]
                    assert len(frames)==1 and json.loads(frames[0].split('=',1)[1])==dict(
                        ok=True, mode='presence_repair', network_blocked=True)
                    assert held.is_file() and not chapter.exists()
                    held.rename(chapter)
                    # Real cached chapters: preserve a local note and a ledger
                    # reference, interrupt a third deletion, recover in a new
                    # process and redownload the removed chapter.
                    empty_slot = None
                    for mode in ('cleanup_start', 'cleanup_corrupt', 'cleanup_recover', 'cleanup_redownload',
                                 'cleanup_ui_pending', 'cleanup_ui_active', 'cleanup_ui_corrupt', 'cleanup_ui_cancel',
                                 'cleanup_ui_stale', 'cleanup_ui_cancel_during', 'cleanup_redownload', 'cleanup_ui_run'):
                        if mode == 'cleanup_corrupt':
                            recovery, = (root/'native-reader-v1'/account/book).glob('*/.native-cleanup')
                            recovery_bytes = recovery.read_bytes()
                            recovery.write_bytes(recovery_bytes+b'corrupt')
                        child = subprocess.run([str(runtime/'luajit'), str(REPO/'spec/koreader/native_direct_batch_probe.lua'),
                                                str(REPO)], input=json.dumps(dict(payload, mode=mode)), text=True,
                                               env=env, cwd=runtime, capture_output=True, timeout=150)
                        if child.returncode: raise AssertionError(child.stdout[-6000:] + child.stderr[-6000:])
                        frames = [line for line in child.stdout.splitlines() if line.startswith('WEREAD_DIRECT_BATCH=')]
                        expected = dict(ok=True, mode=mode)
                        if mode != 'cleanup_redownload': expected['network_blocked'] = True
                        assert len(frames)==1 and json.loads(frames[0].split('=',1)[1])==expected
                        if mode == 'cleanup_corrupt': recovery.write_bytes(recovery_bytes)
                        if mode == 'cleanup_recover':
                            empty_slot = recovery.parent
                            assert not empty_slot.exists()
                            empty_slot.mkdir()
                        if mode == 'cleanup_redownload' and empty_slot is not None:
                            assert len(list(empty_slot.glob('*.epub')))==1
                            empty_slot = None
                with tempfile.TemporaryDirectory(prefix='weread-native-batch-locked-', dir='/dev/shm') as directory:
                    root = Path(directory)
                    for name in ('plugins', 'xdg'):
                        (root/name).mkdir(mode=0o700)
                    extract_candidate(candidate, root/'plugins')
                    env.update(KO_HOME=str(root), XDG_RUNTIME_DIR=str(root/'xdg'))
                    server.resume, server.expired, server.locked = False, False, True
                    server.hold = False
                    server.chapters = []
                    for mode in ('locked', 'offline_locked'):
                        child = subprocess.run([str(runtime/'luajit'), str(REPO/'spec/koreader/native_direct_batch_probe.lua'),
                                                str(REPO)], input=json.dumps(dict(payload, mode=mode)), text=True,
                                               env=env, cwd=runtime, capture_output=True, timeout=150)
                        if child.returncode: raise AssertionError(child.stdout[-6000:] + child.stderr[-6000:])
                        marker = 'WEREAD_DIRECT_BATCH='
                        frames = [line for line in child.stdout.splitlines() if line.startswith(marker)]
                        expected = dict(ok=True, mode=mode)
                        if mode == 'offline_locked': expected['network_blocked'] = True
                        assert len(frames) == 1 and json.loads(frames[0][len(marker):]) == expected
                        assert server.chapters == ['37', '38'] and server.valid and not server.leaked
                with tempfile.TemporaryDirectory(prefix='weread-native-batch-range-', dir='/dev/shm') as directory:
                    root = Path(directory)
                    for name in ('plugins', 'xdg'):
                        (root/name).mkdir(mode=0o700)
                    extract_candidate(candidate, root/'plugins')
                    env.update(KO_HOME=str(root), XDG_RUNTIME_DIR=str(root/'xdg'))
                    server.chapters = []
                    for mode in ('range_cancel', 'range', 'range_repeat', 'offline_range', 'range_copies', 'range_damaged_copy'):
                        child = subprocess.run([str(runtime/'luajit'), str(REPO/'spec/koreader/native_direct_batch_probe.lua'),
                                                str(REPO)], input=json.dumps(dict(payload, mode=mode)), text=True,
                                               env=env, cwd=runtime, capture_output=True, timeout=150)
                        if child.returncode: raise AssertionError(child.stdout[-6000:] + child.stderr[-6000:])
                        marker = 'WEREAD_DIRECT_BATCH='
                        frames = [line for line in child.stdout.splitlines() if line.startswith(marker)]
                        expected = dict(ok=True, mode=mode)
                        if mode == 'offline_range': expected['network_blocked'] = True
                        assert len(frames) == 1 and json.loads(frames[0][len(marker):]) == expected
                        assert server.chapters == ([] if mode == 'range_cancel' else ['38'])
                        assert server.valid and not server.leaked
                for modes in (('range_retry', 'offline_retry'), ('range_interrupted', 'range_reopen', 'offline_retry')):
                    with tempfile.TemporaryDirectory(prefix='weread-native-batch-retry-', dir='/dev/shm') as directory:
                        root = Path(directory)
                        for name in ('plugins', 'xdg'):
                            (root/name).mkdir(mode=0o700)
                        extract_candidate(candidate, root/'plugins')
                        env.update(KO_HOME=str(root), XDG_RUNTIME_DIR=str(root/'xdg'))
                        server.resume, server.expired, server.locked = False, False, False
                        server.interrupt_download = modes[0] == 'range_retry'
                        server.hold = modes[0] == 'range_interrupted'
                        server.hold_marker = root/'hold'
                        server.hold_release, server.hold_done = threading.Event(), threading.Event()
                        server.chapters = []
                        for mode in modes:
                            if mode == 'range_reopen':
                                server.catalog_faults = ['transport', 429]
                            child = subprocess.run([str(runtime/'luajit'), str(REPO/'spec/koreader/native_direct_batch_probe.lua'),
                                                    str(REPO)], input=json.dumps(dict(payload, mode=mode)), text=True,
                                                   env=env, cwd=runtime, capture_output=True, timeout=150)
                            if mode == 'range_interrupted':
                                server.hold_release.set()
                                assert server.hold_done.wait(10)
                                server.hold = False
                            if child.returncode: raise AssertionError(child.stdout[-6000:] + child.stderr[-6000:])
                            marker = 'WEREAD_DIRECT_BATCH='
                            frames = [line for line in child.stdout.splitlines() if line.startswith(marker)]
                            expected = dict(ok=True, mode=mode)
                            if mode == 'offline_retry': expected['network_blocked'] = True
                            assert len(frames) == 1 and json.loads(frames[0][len(marker):]) == expected
                            expected_chapters = ['37', '38'] if mode == 'range_interrupted' else ['37', '38', '38']
                            assert not server.interrupt_download and not server.catalog_faults and server.chapters == expected_chapters
                            assert server.valid and not server.leaked
                with tempfile.TemporaryDirectory(prefix='weread-native-batch-cancel-', dir='/dev/shm') as directory:
                    root = Path(directory)
                    for name in ('plugins', 'xdg'):
                        (root/name).mkdir(mode=0o700)
                    extract_candidate(candidate, root/'plugins')
                    env.update(KO_HOME=str(root), XDG_RUNTIME_DIR=str(root/'xdg'))
                    server.resume, server.expired, server.locked, server.hold = False, False, False, True
                    server.hold_marker, server.hold_release, server.hold_done = root/'hold', threading.Event(), threading.Event()
                    server.chapters = []
                    child = subprocess.run([str(runtime/'luajit'), str(REPO/'spec/koreader/native_direct_batch_probe.lua'),
                                            str(REPO)], input=json.dumps(dict(payload, mode='cancel_running')), text=True,
                                           env=env, cwd=runtime, capture_output=True, timeout=150)
                    server.hold_release.set()
                    assert server.hold_done.wait(10)
                    if child.returncode: raise AssertionError(child.stdout[-6000:] + child.stderr[-6000:])
                    marker = 'WEREAD_DIRECT_BATCH='
                    frames = [line for line in child.stdout.splitlines() if line.startswith(marker)]
                    assert len(frames) == 1 and json.loads(frames[0][len(marker):]) == dict(ok=True, mode='cancel_running')
                    server.hold = False
                    child = subprocess.run([str(runtime/'luajit'), str(REPO/'spec/koreader/native_direct_batch_probe.lua'),
                                            str(REPO)], input=json.dumps(dict(payload, mode='offline_partial')), text=True,
                                           env=env, cwd=runtime, capture_output=True, timeout=150)
                    if child.returncode: raise AssertionError(child.stdout[-6000:] + child.stderr[-6000:])
                    frames = [line for line in child.stdout.splitlines() if line.startswith(marker)]
                    assert len(frames) == 1 and json.loads(frames[0][len(marker):]) == dict(
                        ok=True, mode='offline_partial', network_blocked=True)
        print('PASS: packaged E-Ink batch range, cancel, rate limit, resume and offline reopen at both sizes')
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    run(parser.parse_args().koreader.resolve())
