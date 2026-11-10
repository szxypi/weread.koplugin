#!/usr/bin/env python3
"""Bounded full CB_ chapter protocol, offline unless --saved-session.

Read every normal readable chapter of one explicit shelf ordinal. No failed
chapter is skipped. Only account/shelf/progress/Reader GETs and catalog/content
query POSTs are allowed; one optional protected resource archive is inspected
using the existing full-book resource contract. No account writes or renewal.
Private identities, text, cookies and manifests stay in memory/captured pipes.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import time

from check_owner_full_book import Images
from fetch_weread_epub import decode_content_shards, make_content_params, reader_url_for
from secure_weread_session import SessionStore
from verify_cb_reading import BASE, CbReadingProbe, baseline_position, readable_chapters, source_sample, txt_marker
from verify_cb_progress import cb_ids
from verify_owner_reading import FullBookPreflight
from verify_reader_context import project as reader_context
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import identifier, versions


class CbFullError(ValueError):
    pass


class CbFullReadingProbe(CbReadingProbe):
    MAX_CHAPTERS = 128
    MAX_TOTAL_BYTES = 24 * 1024 * 1024
    protected_resource_url = staticmethod(FullBookPreflight.protected_resource_url)
    public_resource_url = staticmethod(FullBookPreflight.public_resource_url)
    check_protected_archive = FullBookPreflight.check_protected_archive

    def __init__(self, *, interval=1, progress=None):
        super().__init__()
        if type(interval) not in (int, float) or not 0 <= interval <= 5: raise CbFullError('full_interval')
        self.interval = interval
        self.progress = progress or (lambda _value: None)
        self.allowed_chapters = set()
        self.completed = 0
        self.manifest = []

    def read_key(self, stage):
        if stage == 'reader' or stage.startswith(('e_', 't_')):
            if self.chapter not in self.allowed_chapters: raise CbFullError('full_chapter_scope')
            return self.book_id, self.chapter, stage
        return super().read_key(stage)

    def request(self, *args, **kwargs):
        value = super().request(*args, **kwargs)
        if self.interval: time.sleep(self.interval)
        return value

    def prepare(self, book_index=1):
        shelf = self.request('shelf', BASE + '/web/shelf/sync')
        ids = cb_ids(shelf)
        if type(book_index) is not int or not 1 <= book_index <= len(ids): raise CbFullError('full_book_index')
        self.book_id, self.chapter = ids[book_index - 1], None
        self.allowed = {self.book_id}
        self.shelf_ids = [str(row['bookId']) for row in shelf['books']]
        self.shelf_count = len(shelf['books'])
        self.phase = 'catalog'
        record, chapters = readable_chapters(self.request('catalog_before', BASE + '/web/book/chapterInfos',
                                                          dict(bookIds=[self.book_id])), self.book_id)
        if not 2 <= len(chapters) <= self.MAX_CHAPTERS: raise CbFullError('full_chapter_limit')
        info = record.get('book', {})
        if isinstance(info, dict) and info.get('format') not in (None, 'epub'): raise CbFullError('full_format')
        self.allowed_chapters = {identifier(row['chapterUid']) for row in chapters}
        if len(self.allowed_chapters) != len(chapters): raise CbFullError('full_ambiguous_chapters')
        baseline = baseline_position(self.request('progress_before', BASE + '/web/book/getProgress?bookId=' + self.book_id), self.book_id)
        preferred = baseline['chapter'] if baseline['chapter'] != '0' else identifier(chapters[0]['chapterUid'])
        if preferred not in self.allowed_chapters: raise CbFullError('full_resume_chapter_missing')
        total = 0; sample = None; multi = 0; maximum_bodies = 0
        self.phase = 'content'
        self.progress(dict(phase=self.phase, completed=0, total=len(chapters)))
        for row in chapters:
            self.chapter = identifier(row['chapterUid'])
            context = reader_context(dict(book_id=self.book_id), self.request('reader', reader_url_for(self.book_id, self.chapter), as_json=False))
            if identifier(context['current_chapter'].get('chapterUid')) != self.chapter: raise CbFullError('full_reader_chapter')
            self.psvts = context['psvts']
            def read(name):
                return self.request(name, BASE + '/web/book/chapter/' + name,
                                    make_content_params(self.book_id, self.chapter, self.psvts, style=name == 'e_2'), as_json=False)
            e0 = read('e_0')
            if txt_marker(e0, self.book_id, self.chapter): raise CbFullError('full_format')
            raw = decode_content_shards(e0, read('e_1'), read('e_3'))
            size = len(raw.encode()); total += size
            if not 1 <= size <= 2 * 1024 * 1024 or total > self.MAX_TOTAL_BYTES: raise CbFullError('full_source_limit')
            read('e_2')
            images = Images(); images.feed(raw)
            bodies = raw.count('<body'); multi += bodies > 1; maximum_bodies = max(maximum_bodies, bodies)
            digest = hashlib.sha256(raw.encode()).hexdigest()
            self.manifest.append(dict(chapter_uid=self.chapter, raw_sha256=digest, raw_bytes=size, image_references=len(images.sources)))
            if self.chapter == preferred:
                text, offset = source_sample(raw, 'web_xhtml')
                sample = dict(chapter_uid=self.chapter, source_text=text, source_raw_sha256=digest, source_sample_offset=offset)
            self.completed += 1
            self.progress(dict(phase=self.phase, completed=self.completed, total=len(chapters)))
        self.phase = 'compare'
        self.chapter = None
        later, rows = readable_chapters(self.request('catalog_after', BASE + '/web/book/chapterInfos', dict(bookIds=[self.book_id])), self.book_id)
        observed = baseline_position(self.request('progress_after', BASE + '/web/book/getProgress?bookId=' + self.book_id), self.book_id)
        self.last_checks = dict(catalog_unchanged=rows == chapters, versions_unchanged=versions(later) == versions(record),
                                position_unchanged=observed == baseline)
        if not all(self.last_checks.values()) or sample is None: raise CbFullError('full_baseline_changed')
        urls = list(dict.fromkeys(url for row in chapters if (url := self.protected_resource_url(row.get('tar')))))
        resource_files = self.check_protected_archive(urls[0], sample['chapter_uid']) if urls else 0
        self.phase = 'complete'
        self.summary = dict(chapters=len(chapters), source_bytes=total, image_references=sum(row['image_references'] for row in self.manifest),
                            multiple_body_chapters=multi, maximum_bodies=maximum_bodies, protected_archive_files=resource_files)
        sample.update(book_id=self.book_id, shelf_ids=self.shelf_ids, shelf_books=self.shelf_count, source_format='web_xhtml',
                      full_manifest=self.manifest, protected_resource_urls=urls, baseline=baseline)
        self.samples = [sample]
        return sample


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--book-index', type=int, choices=range(1, 9), default=1)
    parser.add_argument('--progress-file', type=Path)
    args = parser.parse_args(argv)
    if not args.saved_session and (args.book_index != 1 or args.progress_file): parser.error('online options require --saved-session')
    report = dict(result='OFFLINE_ONLY', checked_at=datetime.now(timezone.utc).isoformat(), account_data_posts=0,
                  authentication_posts=0, private_source_or_credentials_saved=False)
    saved = web = sample = None
    try:
        if args.saved_session:
            def progress(value):
                if args.progress_file: args.progress_file.write_text(json.dumps(value) + '\n')
            store, web = SessionStore(), CbFullReadingProbe(progress=progress)
            saved = store.load(); web.vid = saved['vid']
            for key, value in saved['cookies'].items(): web.set_cookie(key, value)
            web.verify_account()
            try:
                sample = web.prepare(args.book_index)
            finally:
                web.verify_account()
                report['cookie_rotation_saved'] = save_refreshed_web_session(store, saved, web)
            report.update(result='CB_FULL_CHAPTER_PROTOCOL_VERIFIED', same_owner_verified=True, selected_ordinal=args.book_index,
                          shelf_books=web.shelf_count, baseline_position_unchanged=True, **web.summary)
    except Exception:
        report.update(result='UNVERIFIED', reason='cb_full_protocol_unverified')
    finally:
        if web:
            report.update(completed_chapters=web.completed, validation_phase=web.phase, last_checks=web.last_checks,
                          stages=[{key: row[key] for key in ('stage', 'status', 'api_code') if key in row} for row in web.report['stages']])
            web.samples.clear(); web.manifest.clear(); web.close()
        for private in (saved, sample):
            if private: private.clear()
    print(json.dumps(report, indent=2))
    return 0 if report['result'] in {'OFFLINE_ONLY', 'CB_FULL_CHAPTER_PROTOCOL_VERIFIED'} else 1


if __name__ == '__main__':
    raise SystemExit(main())
