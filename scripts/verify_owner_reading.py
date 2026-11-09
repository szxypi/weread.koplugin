#!/usr/bin/env python3
"""Opt-in real-book selection, download, native reading and offline reopening.

Private source, cookies and native diagnostics cross captured memory pipes only.
The Linux runner confines the disposable profile to tmpfs. No account write or
authentication POST is permitted. The default never opens credentials/network.
"""
import argparse
from datetime import datetime, timezone
import hashlib
from html.parser import HTMLParser
import json
import math
import io
import ipaddress
import re
import subprocess
import time
import tarfile
from urllib.request import Request
from urllib.request import build_opener
from urllib.error import HTTPError
from urllib.parse import urlsplit, urljoin
import zipfile

from fetch_weread_epub import decode_content_shards, make_content_params, normalize_chapter_infos, reader_url_for
from secure_weread_session import COOKIE_NAMES, SessionStore, StoreError
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE, USER_AGENT, NoRedirect, PreflightError, WebSourceProbe, identifier, position, versions
from verify_txt_reading import TxtProbe, select_chapter
from verify_reader_progress import project as project_progress
from verify_reader_context import project as reader_context
from check_owner_full_book import Images

FRAME = b'\nWEREAD_OWNER_READING_RESULT='
FLAGS = {'anonymous_auth', 'transport_guard_selftest', 'plugin_selection', 'native_reader',
         'source_text_visible', 'source_receipt_verified', 'local_source_position_verified',
         'source_navigation_roundtrip', 'source_dialog_verified', 'legacy_progress_units_preserved',
         'page_turn', 'position_checkpoint', 'credential_file_audit', 'workers_reaped'}
COUNTS = {'shelf_books': 5000, 'pages': 100000, 'profile_files_audited': 1024,
          'failed_line': 1000, 'screenshots': 1, 'last_http_status': 599, 'denied_kind': 7,
          'denied_route': 10, 'denied_flags': 511}
KINDS = ('shelf', 'progress', 'reader', 'catalog', 'content', 'resource', 'forbidden')
PHASES = {'init', 'shelf', 'detail', 'prepare', 'native', 'close', 'audit', 'complete'}
RUNNER_ERRORS = {'none', 'child_timeout', 'runner_exception', 'candidate_layout', 'input_limit', 'stage_unverified'}
RUNNER_ERRORS |= {'full_resource_path', 'full_external_image', 'full_image_size', 'full_image_type',
                  'full_svg_external_resource', 'full_private_path', 'full_chapter_scope', 'full_archive_limit',
                  'full_metadata_limit', 'full_metadata_seal', 'full_metadata_scope', 'full_raw_source',
                  'full_render_source', 'full_source_alias', 'full_manifest_resource', 'full_spine_order',
                  'full_unresolved_image', 'full_missing_image_references', 'full_source_image_count',
                  'full_source_text_missing'}


def validate_stage(value, mode, *, full_chapters=1):
    if type(full_chapters) is not int or not 1 <= full_chapters <= 32:
        raise ValueError('reading_scope')
    expected = FLAGS | set(COUNTS) | {'result', 'phase', 'mode', 'requests'}
    if full_chapters > 1:
        expected |= {'native_images_decoded', 'download_error', 'download_error_module', 'download_error_line',
                     'download_error_chapter', 'reader_context_failure', 'reader_identity_shape',
                     'reader_python_projection', 'reader_cookie_snapshot'}
    if not isinstance(value, dict) or set(value) != expected:
        raise ValueError('reading_schema')
    if (type(value['result']) is not str or type(value['phase']) is not str or type(value['mode']) is not str
            or value['result'] not in ('PASS', 'UNVERIFIED') or value['phase'] not in PHASES or value['mode'] != mode
            or any(type(value[k]) is not bool for k in FLAGS)):
        raise ValueError('reading_status')
    if any(type(value[k]) is not int or not 0 <= value[k] <= limit for k, limit in COUNTS.items()):
        raise ValueError('reading_count')
    if full_chapters > 1 and (type(value['native_images_decoded']) is not int or not 0 <= value['native_images_decoded'] <= 4096):
        raise ValueError('full_image_count')
    if full_chapters > 1 and (value['download_error'] not in ('none','resource_scope','request_scope','empty_content','other')
            or value['download_error_module'] not in ('none','content','client','reader_context','position_source','downloader','owner_reading_probe','other')
            or type(value['download_error_line']) is not int or not 0 <= value['download_error_line'] <= 10000
            or value['result'] == 'PASS' and (value['download_error'] != 'none' or value['download_error_module'] != 'none'
                                             or value['download_error_line'])):
        raise ValueError('full_download_error')
    if full_chapters > 1 and (type(value['download_error_chapter']) is not int or not 0 <= value['download_error_chapter'] <= full_chapters
            or value['reader_context_failure'] not in ('none','invalid_identity','invalid_response','book_mismatch','invalid_session','other')
            or value['result']=='PASS' and value['download_error_chapter']):
        raise ValueError('full_reader_error')
    if full_chapters > 1:
        shape = value['reader_identity_shape']
        if (not isinstance(shape,dict) or set(shape) != {'field','kind','zero','null'}
                or shape['field'] not in ('none','book','chapter','progress')
                or shape['kind'] not in ('none','nil','function','number','string','boolean','other')
                or type(shape['zero']) is not bool or type(shape['null']) is not bool):
            raise ValueError('full_reader_shape')
        compared=value['reader_python_projection'];cookie=value['reader_cookie_snapshot']
        if (not isinstance(compared,dict) or set(compared)!={'checked','valid','reason'}
                or type(compared['checked']) is not bool or type(compared['valid']) is not bool
                or compared['reason'] not in ('none','invalid_identity','invalid_response','book_mismatch','invalid_session','other')
                or not isinstance(cookie,dict) or set(cookie)!={'checked','same_login','same_header'}
                or any(type(item) is not bool for item in cookie.values())):
            raise ValueError('full_reader_comparison')
    counts = value['requests']
    limits = (2, 60, max(8, 2*full_chapters+4), 4, max(12, 6*full_chapters),
              512 if full_chapters > 1 else 60, 1024)
    if (not isinstance(counts, list) or len(counts) != len(KINDS)
            or any(type(n) is not int or not 0 <= n <= limit for n, limit in zip(counts, limits))):
        raise ValueError('reading_requests')
    if mode == 'reopen' and any(counts):
        raise ValueError('reading_offline_network')
    if value['result'] == 'PASS' and (not all(value[k] for k in FLAGS) or value['phase'] != 'complete'
            or value['failed_line'] or value['screenshots'] or counts[-1] or value['denied_kind'] or value['denied_route'] or value['denied_flags']
            or value['pages'] < 2 or not value['shelf_books'] or not value['profile_files_audited']
            or mode == 'live' and (not counts[0] or not counts[2] or not counts[3] or not counts[4])):
        raise ValueError('reading_incomplete')
    if value['result'] == 'PASS' and mode == 'live' and full_chapters > 1 and (counts[2] < full_chapters or counts[4] < 3*full_chapters):
        raise ValueError('full_download_incomplete')
    return value


def validate_cookies(cookies, owner):
    if not isinstance(cookies, dict) or not set(cookies) <= COOKIE_NAMES or cookies.get('wr_vid') != owner:
        raise ValueError('reading_session')
    for value in cookies.values():
        if not isinstance(value, str) or not re.fullmatch(r'[!-~]{1,4096}', value) or any(char in value for char in ';"\\'):
            raise ValueError('reading_session')
    if len(cookies.get('wr_skey', '')) < 8:
        raise ValueError('reading_session')
    return cookies


FULL_COUNTS = {'chapters': 32, 'source_image_references': 4096, 'local_image_references': 4096, 'packaged_images': 4096,
               'body_image_references':4096,'converted_footnote_images':4096,'unexplained_image_references':4096,
               'source_text_runs_verified':100000,'unexplained_text_runs':100000}
FULL_FLAGS = {'source_hashes_verified', 'image_references_verified', 'spine_order_verified',
              'zip_crc_verified', 'fresh_offline_package_identical','text_runs_verified'}


def validate_full_book(value, chapters, *, complete=True):
    if type(chapters) is not int or not 2 <= chapters <= 32:
        raise ValueError('full_report_scope')
    if not isinstance(value, dict) or set(value) != set(FULL_COUNTS) | FULL_FLAGS:
        raise ValueError('full_report_schema')
    if (any(type(value[key]) is not int or not 0 <= value[key] <= limit for key, limit in FULL_COUNTS.items())
            or any(type(value[key]) is not bool or complete and not value[key] for key in FULL_FLAGS)
            or value['chapters'] != chapters
            or complete and (value['unexplained_image_references'] or value['unexplained_text_runs']
                or value['body_image_references']+value['converted_footnote_images'] < value['source_image_references']
                or value['local_image_references'] < value['body_image_references']
                or value['local_image_references'] and not value['packaged_images'])):
        raise ValueError('full_report_unverified')
    return value


def decode_envelope(raw, owner, *, mode=None, full_chapters=1):
    """The private cookie envelope is consumed here; never print this value."""
    if not isinstance(raw, bytes) or len(raw) > (8 if full_chapters>1 else 2) * 1024 * 1024 or raw.count(FRAME) != 1:
        raise ValueError('reading_frame')
    value = json.loads(raw.split(FRAME)[1])
    fields={'report','cookies'}
    if mode is not None and full_chapters>1 and isinstance(value,dict) and 'rejected_html' in value:
        fields.add('rejected_html')
        if (not isinstance(value['rejected_html'],str) or len(value['rejected_html'])>6*1024*1024
                or not re.fullmatch(r'[A-Za-z0-9+/]*={0,2}',value['rejected_html'])
                or value.get('report',{}).get('result')=='PASS'):
            raise ValueError('full_private_diagnostic')
    if not isinstance(value, dict) or set(value) != fields:
        raise ValueError('reading_envelope')
    validate_cookies(value['cookies'], owner)
    if mode is not None:
        validate_stage(value['report'], mode, full_chapters=full_chapters)
    else:
        report = value['report']
        fields = {'result', 'tmpfs_profile', 'profile_removed', 'stages', 'runner_error'}
        if full_chapters > 1:
            fields.add('full_book')
        if (not isinstance(report, dict) or set(report) != fields
                or report['result'] not in ('PASS', 'UNVERIFIED') or type(report['tmpfs_profile']) is not bool
                or type(report['profile_removed']) is not bool or type(report['runner_error']) is not str
                or report['runner_error'] not in RUNNER_ERRORS
                or not isinstance(report['stages'], list) or len(report['stages']) > 2):
            raise ValueError('reading_runner')
        for phase, stage in zip(('live', 'reopen'), report['stages']):
            validate_stage(stage, phase, full_chapters=full_chapters)
        if report['result'] == 'PASS' and (not report['tmpfs_profile'] or not report['profile_removed']
                or report['runner_error'] != 'none' or len(report['stages']) != 2
                or any(stage['result'] != 'PASS' for stage in report['stages'])
                or any(report['stages'][0][k] != report['stages'][1][k] for k in ('pages', 'shelf_books'))):
            raise ValueError('reading_runner_incomplete')
        if full_chapters > 1 and (report['result']=='PASS' or report['full_book'] is not None):
            validate_full_book(report['full_book'], full_chapters,complete=report['result']=='PASS')
        if full_chapters > 1 and report['result'] == 'PASS':
            if any(stage['native_images_decoded'] != report['full_book']['packaged_images'] for stage in report['stages']):
                raise ValueError('full_native_images_unverified')
    return value


class SourceText(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.skip = 0
        self.samples = []

    def handle_starttag(self, tag, attrs):
        if tag in ('head', 'style', 'script'):
            self.skip += 1

    def handle_endtag(self, tag):
        if tag in ('head', 'style', 'script'):
            self.skip = max(0, self.skip - 1)

    def handle_data(self, data):
        text = ' '.join(data.split())
        if not self.skip and len(text) >= 32:
            self.samples.append(text[:32])


def reading_position(value, book_id, *, allow_unstarted=False):
    try:
        return position(value, book_id)
    except PreflightError as exc:
        if not allow_unstarted or str(exc) != 'position_has_no_chapter':
            raise
        projected = project_progress(value, book_id)
        if (str(projected.get('chapter_uid')) != '0' or projected['raw_percent'] != 0
                or not projected['has_chapter_offset'] or projected['chapter_offset'] != 0 or projected['chapter_idx'] != 0):
            raise PreflightError('reading_start_unverified') from None
        return dict(chapter='0', offset=0, percent=0)


class ReadingPreflight(WebSourceProbe):
    def __init__(self):
        super().__init__()
        self.shards, self.shelf_ids, self.baseline = {}, [], None

    def request(self, stage, url, body=None, **kwargs):
        value = super().request(stage, url, body, **kwargs)
        if stage in ('e_0', 'e_1', 'e_3'):
            self.shards[stage] = value
        elif stage == 'shelf':
            self.shelf_ids = []
            for row in value.get('books', []):
                try:
                    self.shelf_ids.append(identifier(row.get('bookId')))
                except (PreflightError, AttributeError):
                    pass
        elif stage == 'progress_before':
            self.baseline = position(value, self.book_id)
        return value

    def prepare(self):
        self.select_shelf_book()
        self.inspect(self.book_id)
        if not self.report.get('cloud_position_stable') or not self.report.get('catalog_stable'):
            raise PreflightError('reading_baseline_changed')
        parser = SourceText()
        source = decode_content_shards(*(self.shards[k] for k in ('e_0', 'e_1', 'e_3')))
        parser.feed(source)
        if not parser.samples:
            raise PreflightError('reading_no_text_sample')
        from verify_source_coordinates import FilteredSource
        return dict(book_id=self.book_id, chapter_uid=self.chapter, source_text=parser.samples[0],
                    shelf_ids=self.shelf_ids, shelf_books=self.report['shelf_book_count'], source_format='web_xhtml',
                    source_raw_sha256=hashlib.sha256(source.encode()).hexdigest(),
                    source_sample_offset=FilteredSource(source).locate(parser.samples[0])[0])


class TxtReadingPreflight(TxtProbe):
    def __init__(self):
        super().__init__()
        self.baseline, self.shards = None, {}

    def choose_chapter(self, chapters):
        self.baseline = reading_position(self.request('progress_before', BASE + '/web/book/getProgress?bookId=' + self.book_id),
                                         self.book_id, allow_unstarted=True)
        preferred = self.baseline['chapter']
        if preferred == '0':
            # Match the normal plugin's first readable chapter for an unstarted
            # book. A short first chapter is not replaced with an easier sample.
            readable = [row for row in chapters if type(row.get('wordCount')) in (int, float)
                        and row['wordCount'] > 0 and row.get('title') != '封面']
            if not readable:
                raise PreflightError('reading_no_readable_chapter')
            preferred = identifier(readable[0]['chapterUid'])
        return select_chapter(chapters, preferred)

    def prepare(self):
        if not self.find_sample():
            raise PreflightError('reading_no_txt_sample')
        sample = self.sample
        later, chapters = normalize_chapter_infos(self.request('catalog_after', BASE + '/web/book/chapterInfos',
                                                               dict(bookIds=[self.book_id])), self.book_id)
        after = reading_position(self.request('progress_after', BASE + '/web/book/getProgress?bookId=' + self.book_id),
                                 self.book_id, allow_unstarted=True)
        if after != self.baseline or chapters != sample['chapters'] or versions(later) != versions(sample['record']):
            raise PreflightError('reading_baseline_changed')
        # TXT is literal text: HTML-looking strings and entities must not be parsed.
        lines = [' '.join(line.split()) for line in sample['plain'].replace('\r\n', '\n').replace('\r', '\n').split('\n')]
        source = next((line[:32] for line in lines if len(line) >= 32), None)
        if source is None:
            raise PreflightError('reading_no_text_sample')
        from txt_coordinates import PlainSource
        return dict(book_id=self.book_id, chapter_uid=self.chapter, source_text=source,
                    shelf_ids=self.shelf_ids, shelf_books=self.shelf_count, source_format='web_txt',
                    source_raw_sha256=hashlib.sha256(sample['plain'].encode()).hexdigest(),
                    source_sample_offset=PlainSource(sample['plain']).locate(source)[0])


class FullBookPreflight(ReadingPreflight):
    """Read every chapter of one bounded shelf book; never skip failed chapters."""
    MAX_CHAPTERS = 32
    MAX_TOTAL_BYTES = 24 * 1024 * 1024

    def __init__(self, request_interval=1):
        super().__init__()
        if type(request_interval) not in (int,float) or not math.isfinite(request_interval) or not 0 <= request_interval <= 5:
            raise ValueError('full_request_interval')
        self.request_interval=request_interval

    @staticmethod
    def protected_resource_url(value):
        if not isinstance(value, str) or not 1 <= len(value) <= 8192 or any(ord(c) <= 32 for c in value):
            return None
        if value.startswith('//'):
            value = 'https:' + value
        parts = urlsplit(value)
        if parts.scheme == 'https' and parts.netloc == 'res.weread.qq.com' and not parts.fragment:
            return value
        return None

    def check_protected_archive(self, url, uid):
        if self.protected_resource_url(url) != url or not self.authenticated:
            raise PreflightError('full_archive_scope')
        try:
            opener = getattr(self, 'archive_opener', None) or build_opener(NoRedirect())
            for attempt in range(6):
                row = dict(stage='chapter_resource'); self.report['stages'].append(row)
                headers = {'User-Agent': USER_AGENT, 'Referer': reader_url_for(self.book_id, uid)}
                protected = self.protected_resource_url(url) == url
                if protected:
                    headers['Cookie'] = '; '.join(cookie.name+'='+cookie.value for cookie in self.cookies if cookie.name in COOKIE_NAMES)
                request = Request(url, headers=headers)
                try:
                    with opener.open(request, timeout=20) as response:
                        row['status'] = response.status
                        if response.status != 200:
                            raise PreflightError('full_archive_http')
                        if protected:
                            self.cookies.extract_cookies(response, request)
                        raw = response.read(32*1024*1024+1)
                    break
                except HTTPError as exc:
                    row['status'] = exc.code
                    next_url = urljoin(url, exc.headers.get('Location', ''))
                    redirect = exc.code in (301,302,303,307,308) and attempt < 5 and self.public_resource_url(next_url)
                    exc.close()
                    if not redirect:
                        raise PreflightError('full_archive_http') from None
                    url = next_url
            if len(raw) > 32*1024*1024:
                raise PreflightError('full_archive_limit')
            if raw.startswith(b'PK'):
                with zipfile.ZipFile(io.BytesIO(raw)) as archive:
                    if len(archive.infolist()) > 4096 or sum(item.file_size for item in archive.infolist()) > 128*1024*1024 or archive.testzip():
                        raise PreflightError('full_archive_limit')
                    count = sum(not item.is_dir() for item in archive.infolist())
            else:
                with tarfile.open(fileobj=io.BytesIO(raw), mode='r:*') as archive:
                    members = archive.getmembers()
                    if len(members) > 4096 or sum(item.size for item in members) > 128*1024*1024:
                        raise PreflightError('full_archive_limit')
                    count = sum(item.isfile() for item in members)
            if not count:
                raise PreflightError('full_archive_empty')
            return count
        except PreflightError:
            raise
        except Exception as exc:
            status = getattr(exc, 'code', None)
            if type(status) is int:
                row['status'] = status
            if hasattr(exc, 'close'):
                exc.close()
            raise PreflightError('full_archive_unverified') from None

    @staticmethod
    def public_resource_url(value):
        if not isinstance(value, str) or not 1 <= len(value) <= 8192 or any(ord(c) <= 32 for c in value):
            return False
        parts = urlsplit(value)
        host = parts.hostname or ''
        if parts.scheme not in ('http','https') or parts.netloc != host or parts.fragment:
            return False
        try:
            return ipaddress.ip_address(host).is_global
        except ValueError:
            return bool(re.fullmatch(r'[a-z0-9.-]+\.[a-z]{2,}', host) and not host.endswith(('.local','.localhost','.internal')))

    def request(self, stage, url, body=None, **kwargs):
        if stage == 'progress_before':
            # Full downloads are also valid for an explicitly unstarted book.
            result=WebSourceProbe.request(self, stage, url, body, **kwargs)
        else:
            result=super().request(stage, url, body, **kwargs)
        if self.request_interval:
            time.sleep(self.request_interval)
        return result

    @staticmethod
    def readable(chapters):
        # Match Content.readable_chapters: generated cover is packaged separately.
        result = []
        for row in chapters:
            try:
                words = float(row.get('wordCount', 0)) if type(row.get('wordCount')) is not bool else 0
            except (ValueError, TypeError):
                words = 0
            if words > 0 and row.get('title') != '封面':
                result.append(row)
        return result

    def prepare(self):
        shelf = self.request('shelf', BASE + '/web/shelf/sync')
        rows = shelf.get('books') if isinstance(shelf, dict) else None
        if not isinstance(rows, list) or not 1 <= len(rows) <= 5000:
            raise PreflightError('full_shelf_invalid')
        candidates, seen = [], set()
        for row in rows:
            try:
                key = identifier(row.get('bookId'))
            except (PreflightError, AttributeError):
                continue
            if key in seen:
                continue
            seen.add(key)
            if row.get('format') in ('txt', 'pdf'):
                continue
            words = row.get('wordCount', row.get('totalWords', 100000000))
            if type(words) not in (int, float) or not math.isfinite(words) or words < 0:
                words = 100000000
            candidates.append((words, key))
        record = chapters = None
        for _words, key in sorted(candidates)[:12]:
            self.book_id, self.chapter = key, None
            current, items = normalize_chapter_infos(self.request('catalog_before', BASE + '/web/book/chapterInfos',
                                                                 dict(bookIds=[key])), key)
            if current.get('book', {}).get('format') == 'epub' and 2 <= len(self.readable(items)) <= self.MAX_CHAPTERS:
                record, chapters = current, items
                break
        if chapters is None:
            raise PreflightError('full_no_bounded_book')
        readable = self.readable(chapters)
        uids = [identifier(row.get('chapterUid')) for row in readable]
        if len(set(uids)) != len(uids):
            raise PreflightError('full_ambiguous_chapters')
        self.baseline = reading_position(self.request('progress_before', BASE + '/web/book/getProgress?bookId=' + self.book_id),
                                         self.book_id, allow_unstarted=True)
        manifest, total, sample = [], 0, None
        from verify_source_coordinates import FilteredSource
        for row, uid in zip(readable, uids):
            self.chapter = uid
            context = reader_context(dict(book_id=self.book_id),
                                     self.request('reader', reader_url_for(self.book_id, uid), as_json=False))
            if identifier(context['current_chapter'].get('chapterUid')) != uid:
                raise PreflightError('full_foreign_chapter')
            parts = [self.request(name, BASE + '/web/book/chapter/' + name,
                                  make_content_params(self.book_id, uid, context['psvts'], sc=1), as_json=False)
                     for name in ('e_0', 'e_1', 'e_3')]
            if any(part == '{}' for part in parts) or parts[0].lstrip().startswith('{'):
                raise PreflightError('full_content_unavailable')
            raw = decode_content_shards(*parts)
            size = len(raw.encode())
            total += size
            if not 1 <= size <= 2*1024*1024 or total > self.MAX_TOTAL_BYTES:
                raise PreflightError('full_source_limit')
            digest = hashlib.sha256(raw.encode()).hexdigest()
            parser = SourceText(); parser.feed(raw)
            image_parser=Images();image_parser.feed(raw)
            images = len(image_parser.sources)
            manifest.append(dict(chapter_uid=uid, raw_sha256=digest, raw_bytes=size, image_references=images))
            if sample is None and parser.samples and type(row.get('wordCount')) in (int, float) and row['wordCount'] >= 200:
                text = parser.samples[0]
                sample = dict(chapter_uid=uid, source_text=text, source_raw_sha256=digest,
                              source_sample_offset=FilteredSource(raw).locate(text)[0])
        if sample is None:
            raise PreflightError('full_no_text_sample')
        later, items = normalize_chapter_infos(self.request('catalog_after', BASE + '/web/book/chapterInfos',
                                                            dict(bookIds=[self.book_id])), self.book_id)
        after = reading_position(self.request('progress_after', BASE + '/web/book/getProgress?bookId=' + self.book_id),
                                 self.book_id, allow_unstarted=True)
        if items != chapters or versions(later) != versions(record) or after != self.baseline:
            raise PreflightError('full_baseline_changed')
        protected = [(self.protected_resource_url(row.get('tar')), uid) for row, uid in zip(readable, uids)]
        protected = [(url, uid) for url, uid in protected if url]
        if protected:
            self.check_protected_archive(*protected[0])
        return dict(book_id=self.book_id, shelf_ids=self.shelf_ids, shelf_books=len(rows),
                    source_format='web_xhtml', full_manifest=manifest,
                    protected_resource_urls=list(dict.fromkeys(url for url, _uid in protected)), **sample)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--book-format', choices=('epub', 'txt'), default='epub')
    parser.add_argument('--full-book', action='store_true', help='Verify all chapters of one bounded EPUB shelf book')
    parser.add_argument('--lua-command', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if bool(args.saved_session) != bool(args.lua_command):
        parser.error('pair --saved-session and --lua-command; put --lua-command last')
    if args.full_book and args.book_format != 'epub':
        parser.error('--full-book currently requires --book-format epub')
    report = dict(result='OFFLINE_ONLY', checked_at=datetime.now(timezone.utc).isoformat(), book_format=args.book_format,
                  account_data_writes_attempted=0, authentication_posts_attempted=0,
                  private_data_on_regular_disk=False, screenshots=0)
    saved = probe = payload = envelope = None
    try:
        if args.saved_session:
            store = SessionStore()
            probe = FullBookPreflight() if args.full_book else (TxtReadingPreflight() if args.book_format == 'txt' else ReadingPreflight())
            saved = store.load()
            probe.vid = saved['vid']
            for key, value in saved['cookies'].items():
                probe.set_cookie(key, value)
            probe.verify_account()
            try:
                payload = probe.prepare()
            finally:
                probe.verify_account()
                report['preflight_rotation_saved'] = save_refreshed_web_session(store, saved, probe)
                saved = store.load()
            payload.update(vid=probe.vid, cookies=saved['cookies'])
            full_chapters = len(payload['full_manifest']) if args.full_book else 1
            if args.full_book:
                report.update(reading_scope='full', chapters=full_chapters,
                              source_image_references=sum(row['image_references'] for row in payload['full_manifest']))
            raw = json.dumps(payload, ensure_ascii=False).encode()
            if len(raw) > 256 * 1024:
                raise ValueError('reading_input_limit')
            child = subprocess.run(args.lua_command, input=raw, capture_output=True, timeout=920 if args.full_book else 320)
            envelope = decode_envelope(child.stdout, probe.vid, full_chapters=full_chapters)
            if args.full_book and envelope['report']['result'] == 'PASS':
                if envelope['report']['full_book']['source_image_references'] != report['source_image_references']:
                    raise ValueError('full_image_scope_changed')
            report['ui'] = envelope['report']
            # Verify a rotated snapshot before persisting it, even if a later UI
            # assertion failed. Nothing from the private child stdout is logged.
            probe.cookies.clear()
            for key, value in envelope['cookies'].items():
                probe.set_cookie(key, value)
            probe.verify_account()
            after = reading_position(probe.request('progress_after', BASE + '/web/book/getProgress?bookId=' + probe.book_id),
                                     probe.book_id, allow_unstarted=args.book_format == 'txt' or args.full_book)
            probe.verify_account()
            report['native_rotation_saved'] = save_refreshed_web_session(store, saved, probe)
            report['cloud_position_unchanged'] = after == probe.baseline
            if child.returncode or envelope['report']['result'] != 'PASS' or not report['cloud_position_unchanged']:
                raise ValueError('reading_unverified')
            report.update(result='OWNER_NATIVE_READING_VERIFIED', same_owner_verified=True,
                          source_text_matched=True, fresh_offline_process=True)
    except (StoreError, PreflightError) as exc:
        report.update(result='UNVERIFIED', reason='owner_reading_preflight_failed')
        known = {'identity_invalid','position_book_mismatch','position_has_no_chapter','position_offset_invalid',
                 'position_percent_invalid','position_missing','reading_start_unverified','http_rejected','api_rejected',
                 'full_baseline_changed','full_foreign_chapter','full_content_unavailable','full_archive_http',
                 'full_archive_unverified','full_archive_scope','full_archive_limit','full_archive_empty'}
        report['preflight_failure'] = str(exc) if str(exc) in known else 'other'
    except (ValueError, TypeError, subprocess.TimeoutExpired):
        report.update(result='UNVERIFIED', reason='owner_reading_unverified')
    except Exception:
        report.update(result='UNVERIFIED', reason='owner_reading_probe_failed')
    finally:
        if probe:
            report['preflight_stages'] = [{k: row[k] for k in ('stage', 'status','api_code') if k in row}
                                          for row in probe.report['stages']]
            probe.shards.clear()
            if isinstance(probe, TxtProbe):
                probe.sample = None
            probe.close()
        for private in (saved, payload, envelope):
            if private:
                private.clear()
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report['result'] in ('OFFLINE_ONLY', 'OWNER_NATIVE_READING_VERIFIED') else 1


if __name__ == '__main__':
    raise SystemExit(main())
