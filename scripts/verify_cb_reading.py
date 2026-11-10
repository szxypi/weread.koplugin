#!/usr/bin/env python3
"""Read-only CB_ chapter protocol probe; offline unless --saved-session.

Inspect every CB_ shelf book (maximum eight), one normal resume chapter each.
Only account/shelf/progress/Reader GETs and fixed catalog/content query POSTs
are permitted. No data writes, trial/purchase actions or renewal are present.
Private text, identity, context and cookies remain in memory/captured pipes.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import subprocess
from urllib.parse import urlsplit

from fetch_weread_epub import decode_content_shards, make_content_params, normalize_chapter_infos, reader_url_for, weread_e
from secure_weread_session import SessionStore
from verify_cb_metadata import CbMetadataWebProbe, valid_errors, validate_catalog
from verify_cb_progress import cb_id, cb_ids
from verify_owner_reading import SourceText
from verify_reader_context import project as reader_context
from verify_reader_progress import project as reader_progress
from verify_source_coordinates import CoordinateError
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE, WebSourceProbe, identifier, position, versions


class CbReadingError(ValueError):
    pass


def readable_chapters(value, identity):
    validate_catalog(value, identity)
    record, rows = normalize_chapter_infos(value, identity)
    nested = record.get('book')
    if isinstance(nested, dict) and nested.get('bookId') is not None and nested['bookId'] != identity:
        raise CbReadingError('cb_catalog_identity')
    chapters = [row for row in rows if type(row.get('wordCount')) in (int, float)
                and 0 < row['wordCount'] <= 100000000 and row.get('title') != '封面']
    if not chapters:
        raise CbReadingError('cb_catalog_empty')
    return record, chapters


def choose_chapter(chapters, baseline):
    preferred = baseline['chapter']
    if preferred == '0':
        return chapters[0]
    matches = [row for row in chapters if identifier(row['chapterUid']) == preferred]
    if len(matches) != 1:
        raise CbReadingError('cb_resume_chapter_missing')
    return matches[0]


def baseline_position(value, identity):
    # Preserve the full existing same-book checks; only the zero chapter is
    # represented explicitly for a genuinely unstarted book.
    projected = reader_progress(value, identity)
    if (str(projected.get('chapter_uid')) == '0' and projected['raw_percent'] == 0
            and projected['has_chapter_offset'] and projected['chapter_offset'] == 0 and projected['chapter_idx'] == 0):
        return dict(chapter='0', offset=0, percent=0)
    return position(value, identity)


def txt_marker(text, identity, chapter):
    if not isinstance(text, str) or not text.lstrip().startswith('{'):
        return False
    try:
        value = json.loads(text)
        valid_errors(value)
        if (value.get('bookId') != identity or value.get('chapterUid') is not None
                and identifier(value['chapterUid']) != chapter):
            raise CbReadingError('cb_txt_marker_identity')
    except (ValueError, TypeError, AttributeError):
        raise CbReadingError('cb_txt_marker_invalid') from None
    return True


def source_sample(source, kind):
    if kind == 'web_txt':
        from txt_coordinates import PlainSource
        model = PlainSource(source)
        candidates = [' '.join(line.split())[:32] for line in source.replace('\r\n', '\n').replace('\r', '\n').split('\n')
                      if len(' '.join(line.split())) >= 32]
    else:
        from verify_source_coordinates import FilteredSource
        model = FilteredSource(source, allow_multiple_bodies=True)
        parser = SourceText(); parser.feed(source); candidates = parser.samples
    for text in candidates:
        try:
            return text, model.locate(text)[0]
        except (ValueError, CoordinateError):
            pass
    raise CbReadingError('cb_source_anchor_unavailable')


class CbReadingProbe(CbMetadataWebProbe):
    def __init__(self):
        super().__init__()
        self.used = {}
        self.psvts = None
        self.txt_scope = False
        self.samples = []
        self.shelf_ids = []
        self.shelf_count = 0
        self.phase = 'init'
        self.last_checks = {}
        self.source_shape = {}

    def read_key(self, stage):
        return (self.book_id if stage not in {'account', 'shelf'} else '', stage)

    def guard(self, stage, url, body):
        reads = {'account', 'shelf', 'progress_before', 'progress_after', 'reader', 'catalog_before', 'catalog_after'}
        content = {'e_0', 'e_1', 'e_2', 'e_3', 't_0', 't_1'}
        if stage not in reads | content:
            raise CbReadingError('cb_read_scope')
        if stage not in {'account', 'shelf'} and (not cb_id(self.book_id) or self.book_id not in self.allowed):
            raise CbReadingError('cb_read_scope')
        if stage in content:
            parsed = urlsplit(url)
            expected = {'b', 'c', 'r', 'ct', 'ps', 'pc', 'sc', 'prevChapter', 'st', 's'}
            if (not self.authenticated or not self.chapter or not self.psvts or not isinstance(body, dict)
                    or set(body) != expected or parsed.scheme != 'https' or parsed.netloc != 'weread.qq.com'
                    or parsed.path != '/web/book/chapter/' + stage or parsed.query or parsed.fragment
                    or body['b'] != weread_e(self.book_id) or body['c'] != weread_e(self.chapter) or body['ps'] != self.psvts
                    or type(body['sc']) is not int or body['sc'] != 1 or body['prevChapter'] is not False
                    or type(body['st']) is not int or body['st'] != (1 if stage == 'e_2' else 0)
                    or stage in {'t_0', 't_1'} and not self.txt_scope or len(json.dumps(body)) > 16384):
                raise CbReadingError('cb_content_scope')
        else:
            WebSourceProbe.guard(self, stage, url, body)
        key = self.read_key(stage)
        maximum = 2 if stage == 'account' else 1
        if self.used.get(key, 0) >= maximum:
            raise CbReadingError('cb_read_repeated')
        self.used[key] = self.used.get(key, 0) + 1

    def prepare(self, book_index=None):
        shelf = self.request('shelf', BASE + '/web/shelf/sync')
        self.allowed = set(cb_ids(shelf))
        self.shelf_count = len(shelf['books'])
        self.shelf_ids = [str(row['bookId']) for row in shelf['books']]
        identities = sorted(self.allowed)
        if book_index is not None:
            if type(book_index) is not int or not 1 <= book_index <= len(identities):
                raise CbReadingError('cb_book_index')
            identities = [identities[book_index - 1]]
        for identity in identities:
            self.inspect(identity)
        return self.samples

    def inspect(self, identity):
        self.book_id, self.chapter, self.psvts, self.txt_scope = identity, None, None, False
        self.phase = 'catalog'; self.last_checks = {}
        catalog = self.request('catalog_before', BASE + '/web/book/chapterInfos', dict(bookIds=[identity]))
        record, chapters = readable_chapters(catalog, identity)
        baseline = baseline_position(self.request('progress_before', BASE + '/web/book/getProgress?bookId=' + identity), identity)
        chapter = choose_chapter(chapters, baseline)
        self.chapter = identifier(chapter['chapterUid'])
        context = reader_context(dict(book_id=identity), self.request('reader', reader_url_for(identity, self.chapter), as_json=False))
        if identifier(context['current_chapter'].get('chapterUid')) != self.chapter:
            raise CbReadingError('cb_reader_chapter_mismatch')
        self.psvts = context['psvts']
        shards = {}
        def read(name):
            value = self.request(name, BASE + '/web/book/chapter/' + name,
                                 make_content_params(identity, self.chapter, self.psvts, style=name == 'e_2', sc=1), as_json=False)
            shards[name] = value
            return value
        e0 = read('e_0')
        if txt_marker(e0, identity, self.chapter):
            self.txt_scope = True
            source = decode_content_shards(read('t_0'), read('t_1'), '')
            kind = 'web_txt'
        else:
            source = decode_content_shards(e0, read('e_1'), read('e_3'))
            kind = 'web_xhtml'
        self.phase = 'source'
        self.source_shape = dict(body_open=min(source.count('<body'), 1000), body_close=min(source.count('</body'), 1000),
                                 disallowed_controls=sum(ord(char) < 32 and char not in '\t\r\n' for char in source),
                                 decoded_bytes=len(source.encode()))
        if not 1 <= len(source.encode()) <= 2 * 1024 * 1024:
            raise CbReadingError('cb_source_invalid')
        # The normal downloader also queries the optional style shard. Verify
        # its read contract, without treating style bytes as body text.
        read('e_2')
        later, later_chapters = readable_chapters(self.request('catalog_after', BASE + '/web/book/chapterInfos', dict(bookIds=[identity])), identity)
        after = baseline_position(self.request('progress_after', BASE + '/web/book/getProgress?bookId=' + identity), identity)
        self.phase = 'compare'
        self.last_checks = dict(catalog_unchanged=chapters == later_chapters, versions_unchanged=versions(record) == versions(later),
                                position_unchanged=baseline == after)
        if not all(self.last_checks.values()):
            raise CbReadingError('cb_read_baseline_changed')
        self.phase = 'anchor'
        text, offset = source_sample(source, kind)
        sample = dict(book_id=identity, chapter_uid=self.chapter, source_format=kind, source_text=text,
                      source_raw_sha256=hashlib.sha256(source.encode()).hexdigest(), source_sample_offset=offset,
                      baseline=baseline, chapters=chapters, source=source, shards=shards, context=context,
                      shelf_ids=self.shelf_ids, shelf_books=self.shelf_count)
        self.samples.append(sample); self.phase = 'complete'
        return sample


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--book-index', type=int, choices=range(1, 9), help='Select one ordinal in the complete sorted CB_ shelf set')
    parser.add_argument('--lua-command', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.book_index is not None and not args.saved_session: parser.error('--book-index requires --saved-session')
    if args.lua_command is not None and (not args.saved_session or not args.lua_command): parser.error('--lua-command requires --saved-session and must be last')
    report = dict(result='OFFLINE_ONLY', checked_at=datetime.now(timezone.utc).isoformat(),
                  account_data_posts=0, authentication_posts=0, private_source_or_credentials_saved=False)
    saved = web = None
    try:
        if args.saved_session:
            store, web = SessionStore(), CbReadingProbe()
            saved = store.load(); web.vid = saved['vid']
            for key, value in saved['cookies'].items(): web.set_cookie(key, value)
            web.verify_account(); samples = web.prepare(args.book_index); web.verify_account()
            report['cookie_rotation_saved'] = save_refreshed_web_session(store, saved, web)
            if args.lua_command:
                payload = dict(samples=[{key: row[key] for key in ('source', 'source_text', 'source_format')} for row in samples])
                encoded = json.dumps(payload, ensure_ascii=False).encode()
                if len(encoded) > 20 * 1024 * 1024: raise CbReadingError('cb_model_limit')
                child = subprocess.run(args.lua_command, input=encoded, capture_output=True, timeout=180)
                marker = b'\nWEREAD_CB_READING_MODEL='
                expected = [{key: row[key] for key in ('source_raw_sha256', 'source_sample_offset')} for row in samples]
                if (child.returncode or len(child.stdout) > 65536 or child.stdout.count(marker) != 1
                        or json.loads(child.stdout.split(marker)[1]) != expected):
                    raise CbReadingError('cb_model_unverified')
                report['lua_local_model_matches'] = True
            report.update(result='CB_CHAPTER_READ_VERIFIED', same_owner_verified=True, shelf_books=web.shelf_count,
                          cb_books=len(samples), chapters_read=len(samples), catalog_chapters=sum(len(row['chapters']) for row in samples),
                          source_formats={kind: sum(row['source_format'] == kind for row in samples) for kind in ('web_xhtml', 'web_txt')},
                          source_bytes=sum(len(row['source'].encode()) for row in samples), baseline_positions_unchanged=True)
    except Exception as exc:
        report.update(result='UNVERIFIED', reason='cb_chapter_read_unverified')
        known = {'cb_catalog_identity', 'cb_catalog_empty', 'cb_resume_chapter_missing', 'cb_reader_chapter_mismatch',
                 'cb_txt_marker_invalid', 'cb_source_invalid', 'cb_read_baseline_changed', 'cb_source_anchor_unavailable',
                 'cb_book_index', 'http_rejected', 'api_rejected', 'cb_content_scope', 'cb_read_scope', 'cb_read_repeated'}
        report['failure'] = str(exc) if str(exc) in known else 'source_coordinate_model' if isinstance(exc, CoordinateError) else 'other'
    finally:
        if web:
            report['completed_books'] = len(web.samples)
            report['validation_phase'] = web.phase; report['last_checks'] = web.last_checks
            report['source_shape'] = web.source_shape
            report['stages'] = [{key: row[key] for key in ('stage', 'status', 'api_code') if key in row} for row in web.report['stages']]
            report['read_only_query_posts'] = sum(row['stage'] in {'catalog_before', 'catalog_after', 'e_0', 'e_1', 'e_2', 'e_3', 't_0', 't_1'} for row in web.report['stages'])
            web.samples.clear(); web.close()
        if saved: saved.clear()
    print(json.dumps(report, indent=2))
    return 0 if report['result'] in {'OFFLINE_ONLY', 'CB_CHAPTER_READ_VERIFIED'} else 1


if __name__ == '__main__':
    raise SystemExit(main())
