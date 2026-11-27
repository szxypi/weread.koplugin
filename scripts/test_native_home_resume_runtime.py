#!/usr/bin/env python3
"""Exercise the installed native reader and home across offline processes."""
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
from verify_source_coordinates import FilteredSource

REPO = Path(__file__).resolve().parent.parent
fixture.body = lambda uid: '<html><body>' + ''.join(
    f'<p>Chapter {uid}, synthetic paragraph {index} for pagination.</p>' for index in range(100)) + '</body></html>'


class ResumeHandler(fixture.Handler):
    def dispatch(self):
        target = urlsplit(parse_qs(urlsplit(self.path).query).get('url', [''])[0])
        if (target.hostname, target.path) != ('i.weread.qq.com', '/book/getProgress'):
            return super().dispatch()
        server = self.server
        server.progress_requests += 1
        server.valid &= (self.command == 'GET' and target.query == 'bookId=42' and server.cloud_chapter is not None)
        server.leaked |= any(key.lower() in ('vid', 'accesstoken', 'cookie') for key in self.headers)
        point = dict(bookId='42', chapterUid=server.cloud_chapter, progress=25)
        if server.exact_resume:
            summary = f'Chapter {server.cloud_chapter}, synthetic paragraph 70 for pagination.'
            source = FilteredSource(fixture.body(server.cloud_chapter))
            point.update(summary=summary, chapterOffset=source.starts[''.join(source.characters).index(summary)])
        body = json.dumps(dict(book=point)).encode()
        self.send_response(200 if server.valid else 400)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def frame(child, marker):
    if child.returncode:
        raise AssertionError(child.stdout[-5000:] + child.stderr[-5000:])
    lines = [line for line in child.stdout.splitlines() if line.startswith(marker)]
    assert len(lines) == 1
    return json.loads(lines[0][len(marker):])


def check_read_entry(runtime, candidate, server, width, height, dpi, entry):
    with tempfile.TemporaryDirectory(prefix='weread-native-read-entry-', dir='/dev/shm') as directory:
        root = Path(directory)
        for name in ('xdg', 'settings', 'plugins'):
            (root/name).mkdir(mode=0o700)
        extract_candidate(candidate, root/'plugins')
        env = dict(os.environ, KO_HOME=str(root), XDG_RUNTIME_DIR=str(root/'xdg'),
                   LD_LIBRARY_PATH=str(runtime/'libs'), SDL_VIDEODRIVER='dummy', EMULATE_READER='1',
                   EMULATE_BW_SCREEN='1', EMULATE_BB_TYPE='BB8', EMULATE_READER_W=str(width),
                   EMULATE_READER_H=str(height), EMULATE_READER_DPI=str(dpi), WEREAD_SYNTHETIC='1',
                   WEREAD_DIRECT_OWNER_TMPFS='1')
        server.resume = server.expired = False
        server.chapters = []
        server.valid = True
        server.leaked = False
        server.image_requests = server.tar_requests = 0
        partial = entry in ('shelf_partial', 'shelf_partial_offline')
        offline_shelf = entry == 'shelf_partial_offline'
        server.cloud_chapter = '38' if entry in ('details', 'details_exact', 'shelf', 'shelf_partial') else None
        server.exact_resume = entry in ('details_exact', 'shelf_partial')
        server.progress_requests = 0
        uid = server.cloud_chapter or '37'
        payload = dict(credentials=dict(vid='12345678', accessToken='synthetic-access',
            refreshToken='synthetic-refresh', deviceId='eink334691225'+'0'*19),
            mock_endpoint='http://127.0.0.1:'+str(server.server_port), book_id='42', uid=uid, book_version=1,
            source_sha256=hashlib.sha256(fixture.body(uid).encode()).hexdigest(),
            read_entry='shelf' if partial else entry.removesuffix('_exact'))
        if partial:
            seed = dict(credentials=payload['credentials'], mock_endpoint=payload['mock_endpoint'],
                        mode='single', plugin_profile=True)
            child = subprocess.run([str(runtime/'luajit'), str(REPO/'spec/koreader/native_direct_nav_prepare.lua'),
                                    str(REPO)], input=json.dumps(seed), text=True, env=env, cwd=runtime,
                                   capture_output=True, timeout=90)
            saved = Path(frame(child, 'WEREAD_DIRECT_NAV_PREPARED=')['37'])
            assert saved.is_file() and server.chapters == ['37'] and server.valid and not server.leaked
            server.chapters.clear()
            payload.update(require_cached=True, offline=offline_shelf)
        if server.cloud_chapter is not None:
            payload['cloud_chapter_uid'] = server.cloud_chapter
        if server.exact_resume:
            payload['exact_resume'] = True
        child = subprocess.run([str(runtime/'luajit'), str(REPO/'spec/koreader/native_direct_home_full_owner_probe.lua')],
                               input=json.dumps(payload), text=True, env=env, cwd=runtime, capture_output=True, timeout=90)
        result = frame(child, 'WEREAD_DIRECT_HOME_FULL=')
        assert result['ok'] and result['source_matches'] and Path(result['path']).is_file()
        assert server.chapters == ([] if offline_shelf else [uid]) and server.valid and not server.leaked
        if partial:
            assert (Path(result['path']) == saved) == offline_shelf
        assert server.progress_requests == (3 if server.exact_resume else int(server.cloud_chapter is not None))
        if entry in ('details', 'details_exact', 'catalog'):
            mode = 'detail_catalog_saved' if entry == 'catalog' else 'detail_read_saved'
            offline = dict(mode=mode, path=result['path'])
            child = subprocess.run([str(runtime/'luajit'), str(REPO/'spec/koreader/native_home_resume_probe.lua'), str(REPO)],
                                   input=json.dumps(offline), text=True, env=env, cwd=runtime, capture_output=True, timeout=110)
            assert frame(child, 'WEREAD_NATIVE_HOME=') == dict(ok=True, mode=mode, network_blocked=True)
            assert server.chapters == [uid]


def run(runtime, read_entries_only=False):
    server = ThreadingHTTPServer(('127.0.0.1', 0), ResumeHandler)
    server.cloud_chapter = None
    server.exact_resume = False
    server.progress_requests = 0
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='weread-native-home-package-', dir='/dev/shm') as package:
            candidate = Path(package) / 'candidate.zip'
            subprocess.run(['bash', str(REPO/'scripts/package_release.sh'), str(candidate)], cwd=REPO,
                           check=True, capture_output=True)
            for width, height, dpi in ((600, 800, 167), (1264, 1680, 300)):
                for entry in ('details', 'details_exact', 'catalog', 'shelf', 'shelf_partial', 'shelf_partial_offline'):
                    check_read_entry(runtime, candidate, server, width, height, dpi, entry)
                server.cloud_chapter = None
                if read_entries_only:
                    continue
                with tempfile.TemporaryDirectory(prefix='weread-native-home-', dir='/dev/shm') as root:
                    root = Path(root)
                    for directory in ('xdg', 'settings', 'plugins'):
                        (root/directory).mkdir(mode=0o700)
                    extract_candidate(candidate, root/'plugins')
                    env = dict(os.environ, KO_HOME=str(root), XDG_RUNTIME_DIR=str(root/'xdg'),
                               LD_LIBRARY_PATH=str(runtime/'libs'), SDL_VIDEODRIVER='dummy', EMULATE_READER='1',
                               EMULATE_BW_SCREEN='1', EMULATE_BB_TYPE='BB8', EMULATE_READER_W=str(width),
                               EMULATE_READER_H=str(height), EMULATE_READER_DPI=str(dpi), WEREAD_SYNTHETIC='1')
                    server.resume = server.expired = False
                    server.resume_marker = root/'resume'
                    server.chapters = []
                    server.valid = True
                    server.leaked = False
                    server.image_requests = server.tar_requests = 0
                    payload = dict(credentials=dict(vid='12345678', accessToken='synthetic-access',
                        refreshToken='synthetic-refresh', deviceId='eink334691225'+'0'*19),
                        mock_endpoint='http://127.0.0.1:'+str(server.server_port), mode='full', plugin_profile=True)
                    child = subprocess.run([str(runtime/'luajit'), str(REPO/'spec/koreader/native_direct_nav_prepare.lua'),
                                            str(REPO)], input=json.dumps(payload), text=True, env=env, cwd=runtime,
                                           capture_output=True, timeout=150)
                    prepared = frame(child, 'WEREAD_DIRECT_NAV_PREPARED=')
                    path, alternative = Path(prepared['37']), Path(prepared['38'])
                    for mode in ('record_alternative', 'record_suspended', 'quick_home', 'quick_shelf', 'quick_store',
                                 'reopen', 'detail', 'shelf_detail',
                                 'detail_closed', 'downloads', 'damage', 'shelf_damage', 'no_alternative',
                                 'detail_damage', 'downloads_choose', 'quick_choose',
                                 'downloads_repair', 'downloads_repair_unwritable', 'downloads_missing_all',
                                 'downloads_pending', 'downloads_discard', 'switch'):
                        receipt = path.parent/'receipt.txt'
                        original = receipt.read_bytes() if mode in ('damage', 'detail_damage', 'no_alternative') else None
                        repair = mode in ('downloads_repair', 'downloads_repair_unwritable', 'downloads_missing_all')
                        missing = []
                        if mode in ('shelf_damage', 'downloads_missing_all'):
                            missing.append(path)
                        if mode == 'no_alternative' or repair:
                            missing.append(alternative)
                        marker = alternative.parents[2] / ('.native-presence-' + alternative.parents[1].name)
                        stale = 'native-presence-v1\nkey=' + alternative.parent.name + '\ncopy=0\n'
                        if repair:
                            marker.write_text(stale)
                        if original is not None:
                            receipt.write_bytes(original+b'corrupt')
                        for hidden in missing:
                            hidden.rename(hidden.with_suffix('.hidden'))
                        case = dict(mode=mode, path=str(alternative if mode == 'record_alternative' else path),
                                    alternative=str(alternative))
                        child = subprocess.run([str(runtime/'luajit'), str(REPO/'spec/koreader/native_home_resume_probe.lua'),
                                                str(REPO)], input=json.dumps(case), text=True,
                                               env=env, cwd=runtime, capture_output=True, timeout=150)
                        assert frame(child, 'WEREAD_NATIVE_HOME=') == dict(ok=True, mode=mode, network_blocked=True)
                        if original is not None:
                            assert receipt.read_bytes() == original+b'corrupt'
                            receipt.write_bytes(original)
                        for hidden in missing:
                            assert not hidden.exists()
                            hidden.with_suffix('.hidden').rename(hidden)
                        if repair:
                            expected = stale if mode != 'downloads_repair' else stale.replace(
                                alternative.parent.name, path.parent.name)
                            assert marker.read_text() == expected
                    assert server.chapters == ['37', '38'] and server.valid and not server.leaked
        print('PASS: native-only reading and catalogs from details and bookshelf, and offline details reopening at both sizes')
        print('PASS: partial downloads keep cloud chapter selection online and are selectable offline at both sizes')
        print('PASS: one-tap read from details and bookshelf to a verified cloud location at both sizes')
        if not read_entries_only:
            print('PASS: installed native home resume, offline fresh process, both screen sizes')
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--koreader', type=Path, required=True)
    parser.add_argument('--read-entries-only', action='store_true')
    args=parser.parse_args()
    run(args.koreader.resolve(), args.read_entries_only)
