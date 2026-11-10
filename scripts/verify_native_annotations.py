#!/usr/bin/env python3
"""Validate native chapter highlights/thoughts before Lua integration.

Offline by default. The saved-session mode permits a bounded shelf/catalog
read, chapter underline GETs and thought-list POSTs only. No annotation,
progress, shelf or authorization mutation exists. Private replies and tokens
stay in memory and optional captured Lua pipes, never files or public output.
Endpoint reference: MiuRead eink_client.lua at c1893562aa25a870b8dd076d7be062a3348f823e
(AGPL-3.0-only, Copyright (C) 2026 MiuRead contributors).
"""
import argparse
import copy
from datetime import datetime, timezone
import json
import math
import re
import subprocess
import time
from urllib.parse import parse_qs, urlencode, urlsplit

from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore, StoreError
from verify_eink_login import BASE, NativeProbe, ProbeError
from verify_native_discovery import identity
from verify_translation_preflight import TranslationError, catalog, catalog_body

FRAME = b'\nWEREAD_NATIVE_ANNOTATIONS_RESULT='
MAX_UNDERLINES = 4096


class AnnotationError(ValueError):
    pass


def uid(value):
    if type(value) in (int, float) and math.isfinite(value) and int(value) == value and 0 < value <= 2147483647:
        return str(int(value))
    if isinstance(value, str) and re.fullmatch(r'[1-9][0-9]{0,9}', value) and int(value) <= 2147483647:
        return value
    raise AnnotationError('annotations/invalid_chapter')


def range_value(value):
    if not isinstance(value, str) or not re.fullmatch(r'[0-9]{1,10}-[0-9]{1,10}', value):
        raise AnnotationError('annotations/invalid_range')
    start, end = map(int, value.split('-'))
    if not 0 <= start < end <= 2147483647:
        raise AnnotationError('annotations/invalid_range')
    return value


def scope(value, book_id, chapter_uid):
    if not isinstance(value, dict):
        raise AnnotationError('annotations/invalid_object')
    for name in ('bookId', 'book_id'):
        if value.get(name) is not None and identity(value[name]) != book_id:
            raise AnnotationError('annotations/book_mismatch')
    for name in ('chapterUid', 'chapter_uid'):
        if value.get(name) is not None and uid(value[name]) != chapter_uid:
            raise AnnotationError('annotations/chapter_mismatch')


def project(kind, source, book_id, chapter_uid, requested=None):
    book_id, chapter_uid = identity(book_id), uid(chapter_uid)
    if not book_id:
        raise AnnotationError('annotations/invalid_book')
    scope(source, book_id, chapter_uid)
    for key in ('errcode', 'errCode'):
        if key in source and (type(source[key]) is bool or source[key] not in (None, 0)):
            raise AnnotationError('annotations/rejected')
    if source.get('succ') is not None and source['succ'] not in (True, 1):
        raise AnnotationError('annotations/rejected')
    field = {'underlines': 'underlines', 'thoughts': 'reviews'}.get(kind)
    rows = source.get(field) if field else None
    if not isinstance(rows, list) or len(rows) > (MAX_UNDERLINES if kind == 'underlines' else 30):
        raise AnnotationError('annotations/invalid_rows')
    allowed = validate_batch(requested) if kind == 'thoughts' else set()
    seen = set()
    for row in rows:
        scope(row, book_id, chapter_uid)
        marker = range_value(row.get('range'))
        if marker in seen or kind == 'thoughts' and marker not in allowed:
            raise AnnotationError('annotations/unexpected_range')
        seen.add(marker)
        if kind == 'underlines':
            for name in ('count', 'score', 'type'):
                value = row.get(name)
                if value is not None and (type(value) not in (int, float) or not math.isfinite(value) or not 0 <= value <= 1e12):
                    raise AnnotationError('annotations/invalid_counter')
            continue
        pages = row.get('pageReviews')
        if not isinstance(pages, list) or len(pages) > 30:
            raise AnnotationError('annotations/invalid_thoughts')
        for page in pages:
            scope(page, book_id, chapter_uid)
            review = page.get('review', page)
            scope(review, book_id, chapter_uid)
            for name, maximum in (('content', 65536), ('abstract', 16384), ('contextAbstract', 16384)):
                text = review.get(name)
                if text is not None and (not isinstance(text, str) or len(text.encode()) > maximum):
                    raise AnnotationError('annotations/invalid_text')
            if review.get('range') is not None:
                range_value(review['range'])
    return {field: copy.deepcopy(rows)}


def batch_for(rows):
    return [dict(range=row['range'], maxIdx=0, count=30, synckey=0) for row in rows[:30]]


def validate_batch(batch):
    if not isinstance(batch,list) or not 1 <= len(batch) <= 30:
        raise AnnotationError('annotations/invalid_batch')
    seen=set()
    for item in batch:
        if (not isinstance(item,dict) or set(item)!={'range','maxIdx','count','synckey'}
                or any(type(item[key]) is not int or item[key]!=value for key,value in (('maxIdx',0),('count',30),('synckey',0)))):
            raise AnnotationError('annotations/invalid_batch')
        marker=range_value(item['range'])
        if marker in seen:raise AnnotationError('annotations/invalid_batch')
        seen.add(marker)
    return seen


def projection_difference(expected, actual, path='root'):
    """Fixed diagnostics only: never include response strings or dynamic keys."""
    known={'underlines','reviews','range','count','score','type','pageReviews','review','content','abstract',
           'bookId','chapterUid','metadata','author','totalCount','hasMore','maxIdx','synckey','reviewId'}
    if (not isinstance(expected,(dict,list)) and expected == actual
            and (type(expected) is type(actual) or type(expected) in (int,float) and type(actual) in (int,float))):
        return None
    # Stock LuaJSON encodes numbers with LuaJIT tostring (14 significant digits).
    # Account only for that exact wire rounding of the display-only heat score;
    # identifiers, offsets, counts and all other fields still compare exactly.
    if (re.fullmatch(r'root\[[0-9]+\]\.underlines\[[0-9]+\]\.score',path)
            and type(expected) in (int,float) and type(actual) in (int,float)
            and math.isfinite(expected) and float(format(expected,'.14g')) == actual):
        return None
    if type(expected) is not type(actual):
        return dict(path=path,expected_type=type(expected).__name__,actual_type=type(actual).__name__,kind='type')
    if isinstance(expected,dict):
        if set(expected)!=set(actual):return dict(path=path,kind='keys',expected_count=len(expected),actual_count=len(actual))
        for key in expected:
            difference=projection_difference(expected[key],actual[key],path+'.'+(key if key in known else 'other'))
            if difference:return difference
        return None
    if isinstance(expected,list):
        if len(expected)!=len(actual):return dict(path=path,kind='length',expected_count=len(expected),actual_count=len(actual))
        for index,(first,second) in enumerate(zip(expected,actual)):
            difference=projection_difference(first,second,path+f'[{index}]')
            if difference:return difference
        return None
    return dict(path=path,kind='number' if type(expected) in (int,float) else 'value')


class AnnotationProbe(NativeProbe):
    def __init__(self, opener=None):
        super().__init__(opener)
        self.book_id, self.chapter_uid, self.batch = None, None, None
        self.samples = []

    def guard(self, stage, url, body):
        parsed = urlsplit(url)
        query = parse_qs(parsed.query, keep_blank_values=True)
        if parsed.scheme != 'https' or parsed.netloc != 'i.weread.qq.com' or parsed.fragment:
            raise AnnotationError('annotations/request_outside_scope')
        if stage == 'shelf' and parsed.path == '/shelf/sync' and not query and body is None:
            return
        if self.book_id:
            if stage == 'catalog' and parsed.path == '/book/chapterInfos' and not query and body == catalog_body(self.book_id):
                return
            if stage == 'metadata' and parsed.path == '/book/info' and query == {'bookId': [self.book_id]} and body is None:
                return
        if self.book_id and self.chapter_uid:
            if (stage == 'underlines' and parsed.path == '/book/underlines' and body is None
                    and query == {'bookId': [self.book_id], 'chapterUid': [self.chapter_uid], 'synckey': ['0']}):
                return
            if stage == 'thoughts' and parsed.path == '/book/readreviews' and not query and self.batch and isinstance(body,dict):
                validate_batch(body.get('reviews'))
                if (type(body.get('chapterUid')) is int
                        and body == dict(bookId=self.book_id, chapterUid=int(self.chapter_uid), cht2sMode='', reviews=self.batch)):
                    return
        raise AnnotationError('annotations/request_outside_scope')

    def request(self, stage, url, body=None, credentials=None, timeout=15):
        self.guard(stage, url, body)
        return super().request(stage, url, body, credentials, timeout)

    def inspect(self, credentials, all_batches=False):
        shelf = self.request('shelf', BASE + '/shelf/sync', credentials=credentials)
        books = shelf.get('books')
        if not isinstance(books, list) or not 1 <= len(books) <= 5000:
            raise AnnotationError('annotations/invalid_shelf')
        keys = []
        for row in books:
            key = identity(row.get('bookId')) if isinstance(row, dict) else None
            if key and key not in keys:
                keys.append(key)
            if len(keys) == 2:
                break
        for key in keys:
            self.book_id = key
            info = self.request('metadata', BASE + '/book/info?' + urlencode(dict(bookId=key)), credentials=credentials)
            raw = self.request('catalog', BASE + '/book/chapterInfos', catalog_body(key), credentials)
            chapters = catalog(raw, key, info)
            if chapters['format'] not in ('epub', 'txt'):
                continue
            chosen = sorted((row for row in chapters['chapters'] if row['uid'] > 0 and row.get('wordCount', 0) >= 200),
                            key=lambda row: (-row['wordCount'], row['uid']))[:3]
            for chapter in chosen:
                self.chapter_uid = uid(chapter['uid'])
                raw = self.request('underlines', BASE + '/book/underlines?' + urlencode(
                    dict(bookId=key, chapterUid=self.chapter_uid, synckey=0)), credentials=credentials)
                expected = project('underlines', raw, key, self.chapter_uid)
                self.samples.append(dict(kind='underlines', book_id=key, chapter_uid=self.chapter_uid, source=raw, expected=expected))
                ranges=expected['underlines']
                if ranges:
                    private_bytes=0
                    for start in range(0,len(ranges) if all_batches else min(30,len(ranges)),30):
                        self.batch = batch_for(ranges[start:start+30])
                        if all_batches:time.sleep(1)
                        raw = self.request('thoughts', BASE + '/book/readreviews', dict(
                            bookId=key, chapterUid=int(self.chapter_uid), cht2sMode='', reviews=self.batch), credentials)
                        expected = project('thoughts', raw, key, self.chapter_uid, self.batch)
                        private_bytes+=len(json.dumps(raw,ensure_ascii=False).encode())
                        if private_bytes>5*1024*1024:raise AnnotationError('annotations/private_response_limit')
                        self.samples.append(dict(kind='thoughts', book_id=key, chapter_uid=self.chapter_uid,
                                                 requested=self.batch, source=raw, expected=expected))
                    return self.summary(len(books))
        if not self.samples:
            raise AnnotationError('annotations/no_eligible_chapter')
        return self.summary(len(books))

    def summary(self, shelf_count):
        underlines = [row for sample in self.samples if sample['kind'] == 'underlines' for row in sample['expected']['underlines']]
        thoughts = [row for sample in self.samples if sample['kind'] == 'thoughts' for row in sample['expected']['reviews']]
        def known_page(row):
            value=row.get('hasMore')
            return type(value) is bool or type(value) is int and value in (0,1) or isinstance(value,str) and value in ('0','1')
        page_status_known=bool(thoughts) and all(known_page(row) for row in thoughts)
        complete_totals=bool(thoughts) and all(type(row.get('totalCount')) is int and row['totalCount']==len(row['pageReviews']) for row in thoughts)
        requested=sum(len(sample['requested']) for sample in self.samples if sample['kind']=='thoughts')
        more=sum(row.get('hasMore') in (True,1,'1') for row in thoughts)
        return dict(shelf_book_count=shelf_count, sampled_chapters=sum(sample['kind'] == 'underlines' for sample in self.samples),
                    underlines=len(underlines), thought_ranges=len(thoughts), thought_items=sum(len(row['pageReviews']) for row in thoughts),
                    thought_batches=sum(sample['kind']=='thoughts' for sample in self.samples),
                    requested_ranges=requested,additional_range_pages=more,range_page_status_known=page_status_known,
                    returned_items_match_reported_totals=complete_totals,
                    all_requested_range_pages_complete=page_status_known and not more and complete_totals and len(thoughts)==requested,
                    nonempty_underlines_verified=bool(underlines), nonempty_thoughts_verified=any(row['pageReviews'] for row in thoughts))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--native-http', action='store_true')
    parser.add_argument('--all-batches', action='store_true', help='Read the first thought page for every underline range of the selected chapter')
    parser.add_argument('--lua-command', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.lua_command and not args.saved_session or args.native_http and not (args.saved_session and args.lua_command):
        parser.error('Lua comparison requires saved-session; native-http requires lua-command last')
    report = dict(result='OFFLINE_ONLY', checked_at=datetime.now(timezone.utc).isoformat(), account_data_writes_attempted=0,
                  authentication_posts_attempted=0, private_annotations_saved=False, credentials_written_to_files=False)
    credentials = probe = None
    try:
        if args.saved_session:
            owner = SessionStore().load()['vid']
            credentials = NativeSessionStore().load(owner)
            probe = AnnotationProbe()
            report.update(probe.inspect(credentials,all_batches=True) if args.all_batches else probe.inspect(credentials))
            report['all_batches_requested']=args.all_batches
            if args.all_batches:
                if report['requested_ranges']!=report['underlines']:raise AnnotationError('annotations/incomplete_range_batches')
                report['all_underline_ranges_requested']=True
            if args.lua_command:
                payload = dict(samples=probe.samples,all_batches=args.all_batches)
                if args.native_http:
                    payload['native_credentials'] = credentials
                encoded = json.dumps(payload, ensure_ascii=False).encode()
                if len(encoded) > 12 * 1024 * 1024:
                    raise AnnotationError('annotations/input_limit')
                child = subprocess.run(args.lua_command, input=encoded, capture_output=True, timeout=150)
                if child.returncode or len(child.stdout) > 12 * 1024 * 1024 or child.stdout.count(FRAME) != 1:
                    raise AnnotationError('annotations/lua_probe_failed')
                actual = json.loads(child.stdout.split(FRAME)[1])
                expected = [sample['expected'] for sample in probe.samples]
                difference=projection_difference(expected,actual.get('model'))
                if difference:
                    report['projection_difference']=difference
                    raise AnnotationError('annotations/lua_model_mismatch')
                report['lua_model_matches'] = True
                if args.native_http:
                    difference=projection_difference(expected,actual.get('native'))
                    if difference or actual.get('requests') != len(expected):
                        report['projection_difference']=difference
                        raise AnnotationError('annotations/native_readback_mismatch')
                    report['native_https_matches'] = True
            report.update(result='NATIVE_ANNOTATION_CONTRACT_VERIFIED', same_owner_verified=True)
    except (AnnotationError, StoreError, ProbeError, TranslationError) as exc:
        report.update(result='UNVERIFIED', reason=str(exc))
    except Exception:
        report.update(result='UNVERIFIED', reason='native_annotations_unverified')
    finally:
        if probe:
            report['stages'] = [{key: row[key] for key in ('stage', 'status', 'error_code') if key in row} for row in probe.report['stages']]
        if credentials:
            credentials.clear()
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report['result'] in ('OFFLINE_ONLY', 'NATIVE_ANNOTATION_CONTRACT_VERIFIED') else 1


if __name__ == '__main__':
    raise SystemExit(main())
