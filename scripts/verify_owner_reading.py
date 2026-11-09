#!/usr/bin/env python3
"""Opt-in real-book selection, download, native reading and offline reopening.

Private source, cookies and native diagnostics cross captured memory pipes only.
The Linux runner confines the disposable profile to tmpfs. No account write or
authentication POST is permitted. The default never opens credentials/network.
"""
import argparse
from datetime import datetime, timezone
from html.parser import HTMLParser
import json
import re
import subprocess

from fetch_weread_epub import decode_content_shards, normalize_chapter_infos
from secure_weread_session import COOKIE_NAMES, SessionStore, StoreError
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE, PreflightError, WebSourceProbe, identifier, position, versions
from verify_txt_reading import TxtProbe, select_chapter
from verify_reader_progress import project as project_progress

FRAME = b'\nWEREAD_OWNER_READING_RESULT='
FLAGS = {'anonymous_auth', 'transport_guard_selftest', 'plugin_selection', 'native_reader',
         'source_text_visible', 'source_receipt_verified', 'page_turn', 'position_checkpoint', 'credential_file_audit', 'workers_reaped'}
COUNTS = {'shelf_books': 5000, 'pages': 100000, 'profile_files_audited': 1024,
          'failed_line': 1000, 'screenshots': 1, 'last_http_status': 599, 'denied_kind': 7,
          'denied_route': 10, 'denied_flags': 511}
KINDS = ('shelf', 'progress', 'reader', 'catalog', 'content', 'resource', 'forbidden')
LIMITS = (2, 60, 8, 4, 12, 60, 1024)
PHASES = {'init', 'shelf', 'detail', 'prepare', 'native', 'close', 'audit', 'complete'}
RUNNER_ERRORS = {'none', 'child_timeout', 'runner_exception', 'candidate_layout', 'input_limit', 'stage_unverified'}


def validate_stage(value, mode):
    if not isinstance(value, dict) or set(value) != FLAGS | set(COUNTS) | {'result', 'phase', 'mode', 'requests'}:
        raise ValueError('reading_schema')
    if (type(value['result']) is not str or type(value['phase']) is not str or type(value['mode']) is not str
            or value['result'] not in ('PASS', 'UNVERIFIED') or value['phase'] not in PHASES or value['mode'] != mode
            or any(type(value[k]) is not bool for k in FLAGS)):
        raise ValueError('reading_status')
    if any(type(value[k]) is not int or not 0 <= value[k] <= limit for k, limit in COUNTS.items()):
        raise ValueError('reading_count')
    counts = value['requests']
    if (not isinstance(counts, list) or len(counts) != len(KINDS)
            or any(type(n) is not int or not 0 <= n <= limit for n, limit in zip(counts, LIMITS))):
        raise ValueError('reading_requests')
    if mode == 'reopen' and any(counts):
        raise ValueError('reading_offline_network')
    if value['result'] == 'PASS' and (not all(value[k] for k in FLAGS) or value['phase'] != 'complete'
            or value['failed_line'] or value['screenshots'] or counts[-1] or value['denied_kind'] or value['denied_route'] or value['denied_flags']
            or value['pages'] < 2 or not value['shelf_books'] or not value['profile_files_audited']
            or mode == 'live' and (not counts[0] or not counts[2] or not counts[3] or not counts[4])):
        raise ValueError('reading_incomplete')
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


def decode_envelope(raw, owner, *, mode=None):
    """The private cookie envelope is consumed here; never print this value."""
    if not isinstance(raw, bytes) or len(raw) > 2 * 1024 * 1024 or raw.count(FRAME) != 1:
        raise ValueError('reading_frame')
    value = json.loads(raw.split(FRAME)[1])
    if not isinstance(value, dict) or set(value) != {'report', 'cookies'}:
        raise ValueError('reading_envelope')
    validate_cookies(value['cookies'], owner)
    if mode is not None:
        validate_stage(value['report'], mode)
    else:
        report = value['report']
        if (not isinstance(report, dict) or set(report) != {'result', 'tmpfs_profile', 'profile_removed', 'stages', 'runner_error'}
                or report['result'] not in ('PASS', 'UNVERIFIED') or type(report['tmpfs_profile']) is not bool
                or type(report['profile_removed']) is not bool or type(report['runner_error']) is not str
                or report['runner_error'] not in RUNNER_ERRORS
                or not isinstance(report['stages'], list) or len(report['stages']) > 2):
            raise ValueError('reading_runner')
        for phase, stage in zip(('live', 'reopen'), report['stages']):
            validate_stage(stage, phase)
        if report['result'] == 'PASS' and (not report['tmpfs_profile'] or not report['profile_removed']
                or report['runner_error'] != 'none' or len(report['stages']) != 2
                or any(stage['result'] != 'PASS' for stage in report['stages'])
                or any(report['stages'][0][k] != report['stages'][1][k] for k in ('pages', 'shelf_books'))):
            raise ValueError('reading_runner_incomplete')
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
        parser.feed(decode_content_shards(*(self.shards[k] for k in ('e_0', 'e_1', 'e_3'))))
        if not parser.samples:
            raise PreflightError('reading_no_text_sample')
        return dict(book_id=self.book_id, chapter_uid=self.chapter, source_text=parser.samples[0],
                    shelf_ids=self.shelf_ids, shelf_books=self.report['shelf_book_count'], source_format='web_xhtml')


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
        return dict(book_id=self.book_id, chapter_uid=self.chapter, source_text=source,
                    shelf_ids=self.shelf_ids, shelf_books=self.shelf_count, source_format='web_txt')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--book-format', choices=('epub', 'txt'), default='epub')
    parser.add_argument('--lua-command', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if bool(args.saved_session) != bool(args.lua_command):
        parser.error('pair --saved-session and --lua-command; put --lua-command last')
    report = dict(result='OFFLINE_ONLY', checked_at=datetime.now(timezone.utc).isoformat(), book_format=args.book_format,
                  account_data_writes_attempted=0, authentication_posts_attempted=0,
                  private_data_on_regular_disk=False, screenshots=0)
    saved = probe = payload = envelope = None
    try:
        if args.saved_session:
            store, probe = SessionStore(), (TxtReadingPreflight() if args.book_format == 'txt' else ReadingPreflight())
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
            raw = json.dumps(payload, ensure_ascii=False).encode()
            if len(raw) > 256 * 1024:
                raise ValueError('reading_input_limit')
            child = subprocess.run(args.lua_command, input=raw, capture_output=True, timeout=320)
            envelope = decode_envelope(child.stdout, probe.vid)
            report['ui'] = envelope['report']
            # Verify a rotated snapshot before persisting it, even if a later UI
            # assertion failed. Nothing from the private child stdout is logged.
            probe.cookies.clear()
            for key, value in envelope['cookies'].items():
                probe.set_cookie(key, value)
            probe.verify_account()
            after = reading_position(probe.request('progress_after', BASE + '/web/book/getProgress?bookId=' + probe.book_id),
                                     probe.book_id, allow_unstarted=args.book_format == 'txt')
            probe.verify_account()
            report['native_rotation_saved'] = save_refreshed_web_session(store, saved, probe)
            report['cloud_position_unchanged'] = after == probe.baseline
            if child.returncode or envelope['report']['result'] != 'PASS' or not report['cloud_position_unchanged']:
                raise ValueError('reading_unverified')
            report.update(result='OWNER_NATIVE_READING_VERIFIED', same_owner_verified=True,
                          source_text_matched=True, fresh_offline_process=True)
    except (StoreError, PreflightError):
        report.update(result='UNVERIFIED', reason='owner_reading_preflight_failed')
    except (ValueError, TypeError, subprocess.TimeoutExpired):
        report.update(result='UNVERIFIED', reason='owner_reading_unverified')
    except Exception:
        report.update(result='UNVERIFIED', reason='owner_reading_probe_failed')
    finally:
        if probe:
            report['preflight_stages'] = [{k: row[k] for k in ('stage', 'status') if k in row}
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
