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
from test_native_chapter_archive_runtime import plain_tar
from run_persistent_ui_probe import extract_candidate
from synthetic_upload_epub import build_reading
from verify_source_coordinates import FilteredSource

REPO = Path(__file__).resolve().parent.parent
fixture.body = lambda uid: '<html><body>' + ''.join(
    f'<p>Chapter {uid}, synthetic paragraph {index} for pagination.</p>' for index in range(100)) + '</body></html>'
TXT_EXCERPT = '独立 TXT cloud excerpt & <tag> with literal characters.'
TXT_BODY = ('\ufeff\t原文 & <tag>  \r\n\r' + '\r\n'.join(
    TXT_EXCERPT if index == 70 else f'Synthetic plain text line {index} for pagination. 😀'
    for index in range(100)))
TXT_START_EXCERPT = 'The unique opening words of this synthetic TXT chapter.'
TXT_START_BODY = TXT_START_EXCERPT + '\r\n' + TXT_BODY.removeprefix('\ufeff')


class ResumeHandler(fixture.Handler):
    def book_format(self):
        return 'txt' if self.server.txt_chapter else 'epub'

    def chapter_archive(self, uid):
        if self.server.txt_chapter:
            manifest = json.dumps(dict(bookId='42', chapters=[dict(chapterUid=int(uid))])).encode()
            raw = TXT_START_BODY if self.server.txt_start else TXT_BODY
            return plain_tar([('info.txt', manifest), ('chapter-body', raw.encode())])
        return super().chapter_archive(uid)

    def dispatch(self):
        target = urlsplit(parse_qs(urlsplit(self.path).query).get('url', [''])[0])
        if (target.hostname, target.path) == ('i.weread.qq.com', '/store/search'):
            server = self.server
            server.search_requests += 1
            server.valid &= self.command == 'GET' and parse_qs(target.query) == dict(
                keyword=['Synthetic'], scope=['10'], count=['20'], maxIdx=['0'])
            server.leaked |= any(key.lower() in ('vid', 'accesstoken', 'cookie') for key in self.headers)
            body = json.dumps(dict(books=[dict(bookId='42', title='Synthetic book', author='Fixture', searchIdx=1)],
                                   hasMore=0)).encode()
            self.send_response(200 if server.valid else 400)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if (target.hostname, target.path) != ('i.weread.qq.com', '/book/getProgress'):
            return super().dispatch()
        server = self.server
        server.progress_requests += 1
        server.valid &= (self.command == 'GET' and target.query == 'bookId=42' and server.cloud_chapter is not None)
        server.leaked |= any(key.lower() in ('vid', 'accesstoken', 'cookie') for key in self.headers)
        point = dict(bookId='42', chapterUid=server.cloud_chapter, progress=25)
        if server.cloud_chapter == '0':
            point.update(chapterOffset=0, progress=0)
        if server.exact_resume:
            if server.txt_chapter:
                summary = TXT_START_EXCERPT if server.txt_start else TXT_EXCERPT
                offset = 0 if server.txt_start else len(TXT_BODY[:TXT_BODY.index(summary)].encode('utf-16-le')) // 2
                if server.wrong_txt_offset:
                    offset += 1
            else:
                summary = f'Chapter {server.cloud_chapter}, synthetic paragraph 70 for pagination.'
                source = FilteredSource(fixture.body(server.cloud_chapter))
                offset = source.starts[''.join(source.characters).index(summary)]
            point.update(summary=summary, chapterOffset=offset)
        body = json.dumps(dict(book=point)).encode()
        self.send_response(200 if server.valid else 400)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def frame(child, marker, case=None):
    if child.returncode:
        raise AssertionError(f'{case or marker}\n{child.stdout[-5000:]}{child.stderr[-5000:]}')
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
        legacy = entry == 'shelf_legacy'
        offline_shelf = entry == 'shelf_partial_offline'
        server.txt_chapter = '_txt' in entry
        server.txt_start = entry in ('shelf_txt_start', 'details_txt_start')
        raw_txt = TXT_START_BODY if server.txt_start else TXT_BODY
        exact_txt = server.txt_chapter and entry.endswith(('_exact', '_missing', '_wrong', '_start'))
        missing_txt = entry == 'shelf_txt_missing'
        server.wrong_txt_offset = entry == 'details_txt_wrong'
        unread = (server.txt_chapter and not exact_txt) or entry in ('details_new', 'shelf_new')
        prefer_eink = entry in ('details_preferred', 'shelf_preferred')
        server.cloud_chapter = '38' if exact_txt or prefer_eink or entry in (
            'details', 'details_exact', 'shelf', 'shelf_partial', 'shelf_legacy') else None
        if unread:
            server.cloud_chapter = '0'
        server.exact_resume = exact_txt or prefer_eink or entry in ('details_exact', 'shelf_partial', 'shelf_legacy')
        server.progress_requests = server.search_requests = 0
        uid = '37' if unread else server.cloud_chapter or '37'
        payload = dict(credentials=dict(vid='12345678', accessToken='synthetic-access',
            refreshToken='synthetic-refresh', deviceId='eink334691225'+'0'*19),
            mock_endpoint='http://127.0.0.1:'+str(server.server_port), book_id='42', uid=uid,
            book_version=0 if server.txt_chapter else 1,
            source_sha256=hashlib.sha256((raw_txt if server.txt_chapter else fixture.body(uid)).encode()).hexdigest(),
            read_entry=entry.split('_', 1)[0])
        if server.txt_chapter:
            payload['plain_text'] = True
        if exact_txt:
            payload.update(cloud_excerpt=TXT_START_EXCERPT if server.txt_start else TXT_EXCERPT,
                           txt_start_fixture=server.txt_start, wrong_cloud_offset=server.wrong_txt_offset,
                           missing_txt_resume_source=missing_txt)
        if partial or legacy:
            seed = dict(credentials=payload['credentials'], mock_endpoint=payload['mock_endpoint'],
                        mode='two' if legacy else 'single', plugin_profile=True)
            child = subprocess.run([str(runtime/'luajit'), str(REPO/'spec/koreader/native_direct_nav_prepare.lua'),
                                    str(REPO)], input=json.dumps(seed), text=True, env=env, cwd=runtime,
                                   capture_output=True, timeout=90)
            saved = Path(frame(child, 'WEREAD_DIRECT_NAV_PREPARED=')[uid if legacy else '37'])
            expected_seed = ['37', '38'] if legacy else ['37']
            assert saved.is_file() and server.chapters == expected_seed and server.valid and not server.leaked
            server.chapters.clear()
            payload.update(require_cached=True, offline=offline_shelf)
            if legacy:
                epub_sha256 = hashlib.sha256(saved.read_bytes()).hexdigest()
                original = saved.parent/'native-source.txt'
                original.unlink()
        if server.cloud_chapter is not None:
            payload['cloud_chapter_uid'] = server.cloud_chapter
        if server.exact_resume:
            payload['exact_resume'] = True
        if unread:
            payload['start_unread'] = True
        if entry == 'catalog_pending':
            payload['close_pending'] = True
        if prefer_eink:
            payload['prefer_eink_chapters'] = True
        if entry == 'details_preferred':
            payload['store_search_keyword'] = 'Synthetic'
        child = subprocess.run([str(runtime/'luajit'), str(REPO/'spec/koreader/native_direct_home_full_owner_probe.lua')],
                               input=json.dumps(payload), text=True, env=env, cwd=runtime, capture_output=True, timeout=90)
        result = frame(child, 'WEREAD_DIRECT_HOME_FULL=', entry)
        assert result['ok'] and result['source_matches'] and Path(result['path']).is_file()
        assert server.search_requests == int(entry == 'details_preferred')
        chapter_requests = [] if offline_shelf else [uid, uid] if missing_txt else [uid]
        assert server.chapters == chapter_requests and server.valid and not server.leaked
        if partial:
            assert (Path(result['path']) == saved) == offline_shelf
        if legacy:
            assert Path(result['path']) == saved and hashlib.sha256(saved.read_bytes()).hexdigest() == epub_sha256
            assert not original.exists()
        if server.txt_chapter:
            assert server.image_requests == server.tar_requests == 0
            assert not Path(result['path']).with_name('native-source.txt').exists()
            original = Path(result['path']).with_name('native-plain-source.txt')
            if missing_txt:
                assert not original.exists()
            else:
                assert original.read_bytes() == raw_txt.encode()
            assert result['cloud_position_verified'] == (exact_txt and not server.wrong_txt_offset)
        expected_reads = 3 if server.exact_resume else 2 if unread else int(server.cloud_chapter is not None)
        if server.wrong_txt_offset:
            expected_reads = 2
        assert server.progress_requests == expected_reads
        if payload['read_entry'] in ('details', 'catalog') or server.txt_chapter:
            mode = {'details': 'detail_read_saved', 'catalog': 'detail_catalog_saved', 'shelf': 'reopen'}[payload['read_entry']]
            offline = dict(mode=mode, path=result['path'])
            child = subprocess.run([str(runtime/'luajit'), str(REPO/'spec/koreader/native_home_resume_probe.lua'), str(REPO)],
                                   input=json.dumps(offline), text=True, env=env, cwd=runtime, capture_output=True, timeout=110)
            assert frame(child, 'WEREAD_NATIVE_HOME=') == dict(ok=True, mode=mode, network_blocked=True)
            assert server.chapters == chapter_requests


def run(runtime, read_entries_only=False):
    server = ThreadingHTTPServer(('127.0.0.1', 0), ResumeHandler)
    server.cloud_chapter = None
    server.txt_chapter = False
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
                for entry in ('details_txt_start', 'shelf_txt_start', 'details_txt_exact', 'shelf_txt_exact', 'shelf_txt_missing', 'details_txt_wrong',
                              'details_txt', 'shelf_txt', 'details_preferred', 'shelf_preferred', 'details', 'details_exact',
                              'details_new', 'catalog', 'catalog_pending', 'shelf', 'shelf_new', 'shelf_partial',
                              'shelf_partial_offline', 'shelf_legacy'):
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
                    standard_path = root/'standard.epub'
                    standard_bytes = build_reading()
                    standard_path.write_bytes(standard_bytes)
                    for mode in ('record_alternative', 'record_suspended', 'close_home', 'quick_home', 'quick_shelf', 'quick_store',
                                 'shelf_close', 'shelf_close_prior', 'reopen', 'detail', 'shelf_detail',
                                 'detail_closed', 'downloads', 'damage', 'shelf_damage', 'no_alternative',
                                 'detail_damage', 'downloads_choose', 'quick_choose',
                                 'downloads_repair', 'downloads_repair_unwritable', 'downloads_missing_all',
                                 'downloads_pending', 'downloads_discard', 'record_standard', 'select_standard_detail',
                                 'select_standard_downloads', 'select_native_downloads', 'select_removed_downloads',
                                 'standard_cancel', 'standard_home', 'standard_shelf', 'standard_downloads', 'switch'):
                        standard = mode.startswith('standard_')
                        receipt = path.parent/'receipt.txt'
                        original = receipt.read_bytes() if standard or mode in ('damage', 'detail_damage', 'no_alternative') else None
                        repair = mode in ('downloads_repair', 'downloads_repair_unwritable', 'downloads_missing_all')
                        missing = []
                        if mode in ('shelf_damage', 'downloads_missing_all'):
                            missing.append(path)
                        if standard or mode == 'no_alternative' or repair:
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
                        if mode == 'record_standard':
                            case['path'] = str(standard_path)
                        if standard or mode.startswith('select_'):
                            case['standard'] = str(standard_path)
                        child = subprocess.run([str(runtime/'luajit'), str(REPO/'spec/koreader/native_home_resume_probe.lua'),
                                                str(REPO)], input=json.dumps(case), text=True,
                                               env=env, cwd=runtime, capture_output=True, timeout=150)
                        assert frame(child, 'WEREAD_NATIVE_HOME=', f'{width}x{height} {mode}') == dict(
                            ok=True, mode=mode, network_blocked=True)
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
                    assert standard_path.read_bytes() == standard_bytes
                    assert server.chapters == ['37', '38'] and server.valid and not server.leaked
        print('PASS: native-only reading and catalogs from details and bookshelf, and offline details reopening at both sizes')
        print('PASS: preferred E-Ink reading with both authorizations from bookstore details and bookshelf at both sizes')
        print('PASS: partial downloads keep cloud chapter selection online and are selectable offline at both sizes')
        print('PASS: one-tap read from details and bookshelf to a verified cloud location at both sizes')
        print('PASS: raw TXT offsets and offline pages, including missing source and mismatched cloud offset at both sizes')
        print('PASS: one-tap read opens the first chapter of a confirmed unread book at both sizes')
        print('PASS: precise cloud continuation reuses the saved EPUB without its original at both sizes')
        print('PASS: a newly downloaded chapter saves the last offline page and reminder on close at both sizes')
        if not read_entries_only:
            print('PASS: installed native home resume, offline fresh process, both screen sizes')
            print('PASS: quick menu closes to WeRead home and reopens the same offline page at both sizes')
            print('PASS: normal KOReader close preserves the verified chapter chosen from the offline shelf at both sizes')
            print('PASS: quick offline turns save a reminder on close and preserve prior reminders at both sizes')
            print('PASS: missing E-Ink resume can open the standard downloaded page or cancel at both sizes')
            print('PASS: choose either available download, keep its saved page and reject a removed copy at both sizes')
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
