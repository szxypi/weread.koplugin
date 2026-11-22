#!/usr/bin/env python3
"""Bounded read-only comparison of one E-Ink chapter and its Web source.

Offline by default. In saved-session mode, the chapter must be explicitly
free or owned in a freshly read catalog; automatic purchasing is disabled.
Credentials, downloaded packages, filenames and actual text stay in memory.
No progress, shelf, authorization or other account writes are sent.
"""
import argparse
import base64
from datetime import datetime, timezone
import hashlib
from html.parser import HTMLParser
import json
import resource
import subprocess
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import Request

from native_chapter_package import MAX_ARCHIVE, PackageError, password, read
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore, StoreError
from verify_eink_login import BASE, HEADERS, NativeProbe, ProbeError
from verify_native_discovery import identity
from verify_translation_preflight import TranslationError, TranslationWebProbe, catalog, catalog_body


class VisibleText(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.hidden = 0
        self.parts = []

    def handle_starttag(self, tag, attrs):
        if tag in ('script', 'style'):
            self.hidden += 1

    def handle_endtag(self, tag):
        if tag in ('script', 'style') and self.hidden:
            self.hidden -= 1

    def handle_data(self, data):
        if not self.hidden:
            self.parts.append(data)


def visible(source, html):
    value = source.decode('utf-8')
    if html:
        parser = VisibleText()
        parser.feed(value)
        parser.close()
        value = ''.join(parser.parts)
    return ''.join(value.split())


class ChapterProbe(NativeProbe):
    def __init__(self, opener=None, capture_for_lua=False):
        super().__init__(opener)
        self.allowed = set()
        self.archive_url = None
        self.archive_attempted = False
        self.capture_for_lua = capture_for_lua
        self.lua_sample = None

    def guard(self, stage, url, body):
        parsed = urlsplit(url)
        if parsed.scheme != 'https' or parsed.netloc != 'i.weread.qq.com' or parsed.fragment:
            raise ProbeError('chapter/request_outside_scope')
        if stage == 'shelf' and url == BASE + '/shelf/sync' and body is None:
            return
        if stage == 'book' and body is None and any(url == BASE + '/book/info?' + urlencode({'bookId': key}) for key in self.allowed):
            return
        if stage == 'catalog' and url == BASE + '/book/chapterInfos' and any(body == catalog_body(key) for key in self.allowed):
            return
        raise ProbeError('chapter/request_outside_scope')

    def request(self, stage, url, body=None, credentials=None, timeout=15):
        self.guard(stage, url, body)
        return super().request(stage, url, body, credentials, timeout)

    def download(self, url, credentials):
        if self.archive_attempted or not self.archive_url or url != self.archive_url:
            raise ProbeError('chapter/download_outside_scope')
        self.archive_attempted = True
        headers = dict(HEADERS, vid=credentials['vid'], accessToken=credentials['accessToken'])
        try:
            with self.opener.open(Request(url, headers=headers), timeout=30) as response:
                if response.status != 200:
                    raise ProbeError('chapter/http_rejected')
                envelope = response.headers.get('encryptkey')
                raw = response.read(MAX_ARCHIVE + 1)
        except HTTPError as exc:
            code = exc.code
            exc.close()
            raise ProbeError('chapter/http_' + str(code)) from None
        except (URLError, OSError, TimeoutError):
            raise ProbeError('chapter/connection_failed') from None
        if len(raw) > MAX_ARCHIVE or not envelope:
            raise ProbeError('chapter/archive_or_envelope_missing')
        return raw, envelope

    def inspect(self, credentials, book_offset=0):
        if type(book_offset) is not int or not 0 <= book_offset <= 50:
            raise ProbeError('chapter/invalid_book_offset')
        shelf = self.request('shelf', BASE + '/shelf/sync', credentials=credentials)
        rows = shelf.get('books')
        if not isinstance(rows, list) or not 1 <= len(rows) <= 5000:
            raise ProbeError('chapter/invalid_shelf')
        ids = []
        for row in rows:
            book_id = identity(row.get('bookId')) if isinstance(row, dict) else None
            if book_id and book_id not in ids:
                ids.append(book_id)
            if len(ids) == book_offset + 4:
                break
        ids = ids[book_offset:book_offset + 4]
        self.allowed = set(ids)
        for book_id in ids:
            info = self.request('book', BASE + '/book/info?' + urlencode({'bookId': book_id}), credentials=credentials)
            raw = self.request('catalog', BASE + '/book/chapterInfos', catalog_body(book_id), credentials=credentials)
            model = catalog(raw, book_id, info)
            chapters = [row for row in model['chapters'] if row['uid'] > 0
                        and row.get('wordCount', 0) >= 200 and row['free_or_owned']]
            if model['format'] not in ('epub', 'txt') or not chapters:
                continue
            if model['format'] == 'epub' and model['version'] is None:
                continue
            chosen = min(chapters, key=lambda row: row['uid'])
            uid = str(chosen['uid'])
            fields = dict(bookId=book_id, chapters=('0,' + uid if model['format'] == 'epub' else uid),
                          bookType=model['format'], bookVersion=(model['version'] if model['format'] == 'epub' else 0),
                          pf='wechat_wx-2001-android-100-weread', pfkey='pfKey', zoneId=1, quote='', release=1,
                          stopAutoPayWhenBNE=1, preload=2, preview=0, offline=1)
            self.archive_url = BASE + '/book/chapterdownload?' + urlencode(fields)
            data, envelope = self.download(self.archive_url, credentials)
            decoded = read(data, password(envelope, credentials['vid']), uid)
            if self.capture_for_lua:
                self.lua_sample = dict(archive=base64.b64encode(data).decode(), envelope=envelope,
                                       vid=credentials['vid'], chapter_uid=uid)
            return {'book_id': book_id, 'expected': model}, chosen, decoded
        raise ProbeError('chapter/no_eligible_sample')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--book-offset', type=int, default=0, choices=range(0, 51))
    lua = parser.add_mutually_exclusive_group()
    lua.add_argument('--lua-command', nargs=argparse.REMAINDER)
    lua.add_argument('--lua-source-command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.book_offset and not args.saved_session:
        parser.error('book offset requires saved session')
    if (args.lua_command or args.lua_source_command) and not args.saved_session:
        parser.error('Lua comparison requires saved session')
    report = dict(result='OFFLINE_ONLY', checked_at=datetime.now(timezone.utc).isoformat(),
                  account_data_writes=0, authorization_requests=0, native_download_requests=0,
                  credentials_or_content_saved=False)
    if args.saved_session:
        probe = None
        try:
            resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
            saved = SessionStore().load()
            credentials = NativeSessionStore().load(saved['vid'])
            probe = ChapterProbe(capture_for_lua=bool(args.lua_command))
            sample, chapter, native = probe.inspect(credentials, args.book_offset)
            report.update(native_package_decoded=True, native_format='html' if native['html'] else 'text',
                          archive_entries=native['entry_count'], encrypted_entries=native['encrypted_entries'],
                          chapter_parts=native['body_parts'], has_manifest=native['has_manifest'],
                          parent_resources=native['parent_resources'],
                          image_signatures_recognized=native['image_signatures_recognized'], unusable_resources=native['unusable_resources'],
                          explicit_free_or_owned=True, native_download_requests=1)
            web = TranslationWebProbe()
            web.vid = saved['vid']
            for name, value in saved['cookies'].items():
                web.set_cookie(name, value)
            web.verify_account()
            web_result = web.inspect_content(sample, chapter_uid=chapter['uid'])
            if not web_result.get('content_decoded'):
                raise ProbeError('chapter/web_content_unavailable')
            web_source = web.content_sample['source'].encode()
            native_text, web_text = visible(native['source'], native['html']), visible(web_source, True)
            if not native_text or not web_text:
                raise ProbeError('chapter/visible_text_empty')
            report['same_book_chapter'] = True
            report['byte_identical'] = native['source'] == web_source
            report['visible_text_equal_ignoring_whitespace'] = native_text == web_text
            if args.lua_command:
                payload = json.dumps({'samples': [probe.lua_sample]}, separators=(',', ':')).encode()
                child = subprocess.run(args.lua_command, input=payload, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, timeout=120)
                marker = b'\nWEREAD_NATIVE_ARCHIVE_RESULT='
                if child.returncode or len(child.stdout) > 65536 or child.stdout.count(marker) != 1:
                    raise ProbeError('chapter/lua_probe_failed')
                actual = json.loads(child.stdout.split(marker, 1)[1])
                digest = lambda value: hashlib.sha256(value).hexdigest()
                assets = [dict(digest=digest(item['data']), mime=item['media_type'], safe_href=True,
                               parent_source='../' in item['source']) for item in native['assets']]
                expected = dict(ok=True, body_sha256=digest(native['source']), css_sha256=digest(native['css']),
                                is_text=not native['html'], web_coordinate_authority=False, assets=assets,
                                image_signatures_recognized=native['image_signatures_recognized'],
                                unusable_resources=native['unusable_resources'])
                if actual != {'samples': [expected]}:
                    raise ProbeError('chapter/lua_comparison_mismatch')
                report['koreader_lua_package_matches'] = True
            if args.lua_source_command:
                payload = json.dumps(dict(credentials=credentials, book_id=sample['book_id'], uid=str(chapter['uid'])),
                                     separators=(',', ':')).encode()
                child = subprocess.run(args.lua_source_command, input=payload, stdout=subprocess.PIPE,
                                       stderr=subprocess.PIPE, timeout=120)
                marker = b'\nWEREAD_NATIVE_SOURCE_RESULT='
                report['lua_source_exit'] = child.returncode
                report['lua_source_marker_count'] = child.stdout.count(marker)
                if len(child.stdout) > 65536 or child.stdout.count(marker) != 1:
                    raise ProbeError('chapter/lua_source_output')
                actual = json.loads(child.stdout.split(marker, 1)[1])
                if child.returncode:
                    allowed = {'invalid', 'session_changed', 'rate_limited', 'auth_expired', 'service_rejected',
                               'not_entitled', 'unavailable'}
                    reason = actual.get('reason') if isinstance(actual, dict) else None
                    raise ProbeError('chapter/lua_source_' + (reason if reason in allowed else 'failed'))
                digest = lambda value: hashlib.sha256(value).hexdigest()
                assets = [dict(digest=digest(item['data']), mime=item['media_type'], safe_href=True,
                               parent_source='../' in item['source']) for item in native['assets']]
                expected = dict(ok=True, requests=3, body_sha256=digest(native['source']), css_sha256=digest(native['css']),
                                is_text=not native['html'], web_coordinate_authority=False, assets=assets,
                                image_signatures_recognized=native['image_signatures_recognized'],
                                unusable_resources=native['unusable_resources'])
                if actual != expected:
                    raise ProbeError('chapter/lua_source_mismatch')
                report['koreader_native_source_matches'] = True
                report['koreader_native_source_requests'] = 3
            report['result'] = 'NATIVE_AND_WEB_CHAPTER_COMPARED'
        except (PackageError, ProbeError, StoreError, TranslationError) as exc:
            report.update(result='UNVERIFIED', reason=str(exc))
        except Exception:
            report.update(result='UNVERIFIED', reason='chapter/verification_failed')
        finally:
            if probe is not None:
                report['native_download_requests'] = int(probe.archive_attempted)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 1 if report['result'] == 'UNVERIFIED' else 0


if __name__ == '__main__':
    raise SystemExit(main())
