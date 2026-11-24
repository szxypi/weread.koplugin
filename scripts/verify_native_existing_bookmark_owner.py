#!/usr/bin/env python3
"""Read-only validation of an existing owner's native bookmark and offline reopen."""
import argparse
import hashlib
import json
import resource
from types import SimpleNamespace
from urllib.parse import urlencode

from annotation_experiment_model import digest
from bookmark_point import from_mark
from fetch_weread_epub import decode_content_shards, make_content_params, read_reader_state, reader_url_for
from my_cloud_marks_model import identifier, project as marks_project
from native_chapter_package import password, read
from native_direct_cross_bookmark_trial import prepare_origin, verify
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_annotation_experiment import AnnotationProbe
from verify_eink_login import BASE as NATIVE, NativeProbe
from verify_native_chapter_package import ChapterProbe
from verify_owner_reading import reading_position
from verify_translation_preflight import catalog, catalog_body, save_refreshed_web_session
from verify_web_source_progress import BASE, WebSourceProbe


def eligible_point(source, book, uid, row):
    """Bind the existing mark to the exact source without exposing its text."""
    if not isinstance(source, bytes) or not isinstance(row, dict):
        raise ValueError('owner_bookmark/source')
    point = from_mark(source.decode('utf-8'), book, uid, row)
    if point['raw_sha256'] != hashlib.sha256(source).hexdigest():
        raise ValueError('owner_bookmark/source')
    return point


def select(native, credentials):
    shelf = native.request('shelf', NATIVE + '/shelf/sync', credentials=credentials)
    notebooks = native.request('notebooks', NATIVE + '/user/notebooks?count=100', credentials=credentials)
    if not isinstance(shelf.get('books'), list) or not isinstance(notebooks.get('books'), list):
        raise ValueError('owner_bookmark/shelf')
    ids = {str(row.get('bookId')) for row in shelf['books'] if isinstance(row, dict)
           and identifier(str(row.get('bookId')))}
    choices = []
    for row in notebooks['books']:
        book = row.get('book', row) if isinstance(row, dict) else None
        identity = str(book.get('bookId')) if isinstance(book, dict) else ''
        count = row.get('bookmarkCount') if isinstance(row, dict) else None
        if identity in ids and type(count) is int and count > 0:
            choices.append((count, identity))
    for _count, book in sorted(choices, reverse=True)[:15]:
        response = native.request('marks', NATIVE + '/book/bookmarklist?' + urlencode(dict(bookId=book, synckey=0)),
                                  credentials=credentials)
        marks = marks_project(response, book, credentials['vid'], 1)
        points = [row for row in marks['updated'] if row.get('type') == 0 and row.get('range')
                  and isinstance(row.get('bookmarkId'), str)]
        if not points:
            continue
        probe = ChapterProbe();probe.allowed = {book}
        info = probe.request('book', NATIVE + '/book/info?' + urlencode(dict(bookId=book)), credentials=credentials)
        model = catalog(probe.request('catalog', NATIVE + '/book/chapterInfos', catalog_body(book),
                                      credentials=credentials), book, info)
        if model['format'] != 'epub' or model['version'] is None:
            continue
        available = [chapter for chapter in model['chapters'] if chapter.get('free_or_owned') is True
                     and chapter.get('wordCount', 0) > 0]
        for chapter in available:
            uid = str(chapter['uid'])
            rows = [row for row in points if str(row.get('chapterUid')) == uid]
            if not rows or not any(str(other['uid']) != uid for other in available):
                continue
            fields = dict(bookId=book, chapters='0,' + uid, bookType='epub', bookVersion=model['version'],
                          pf='wechat_wx-2001-android-100-weread', pfkey='pfKey', zoneId=1, quote='',
                          release=1, stopAutoPayWhenBNE=1, preload=2, preview=0, offline=1)
            probe.archive_url = NATIVE + '/book/chapterdownload?' + urlencode(fields)
            archive, envelope = probe.download(probe.archive_url, credentials)
            chapter_source = read(archive, password(envelope, credentials['vid']), uid)
            if not chapter_source['html']:
                continue
            raw = chapter_source['source']
            for row in rows:
                try:
                    point = eligible_point(raw, book, uid, row)
                except (ValueError, UnicodeError, KeyError, TypeError):
                    continue
                return dict(book_id=book, uid=uid, book_version=model['version'], source=raw,
                            source_sha256=hashlib.sha256(raw).hexdigest()), row, point
    raise ValueError('owner_bookmark/no_eligible_sample')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--lua-command', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if bool(args.saved_session) != bool(args.lua_command):
        parser.error('saved session and private runner required together')
    report = dict(result='OFFLINE_ONLY', account_data_writes=0, authentication_posts=0)
    if not args.saved_session:
        print(json.dumps(report));return 0
    saved = credentials = web = None;phase = 'session'
    try:
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        session = SessionStore();saved = session.load();credentials = NativeSessionStore().load(saved['vid'])
        phase = 'sample';source, row, point = select(NativeProbe(), credentials)
        book, uid = source['book_id'], source['uid']
        notes = AnnotationProbe();notes.identity = book;notes.grant = digest(credentials)
        phase = 'baseline';before = notes.observe(credentials, 'existing_bookmark_before')
        actual = before['marks']['updated'].get(row['bookmarkId'])
        if actual != row:
            raise ValueError('owner_bookmark/baseline_changed')
        phase = 'origin';origin = prepare_origin(credentials, source)
        phase = 'web_source';web = WebSourceProbe();web.vid = saved['vid'];web.book_id = book;web.chapter = uid
        for key, value in saved['cookies'].items():web.set_cookie(key, value)
        web.verify_account()
        web_before = reading_position(web.request('progress_before', BASE + '/web/book/getProgress?bookId=' + book), book)
        reader = read_reader_state(web.request('reader', reader_url_for(book, uid), as_json=False))
        fields = make_content_params(book, uid, reader.psvts, sc=1)
        parts = [web.request(key, BASE + '/web/book/chapter/' + key, fields, as_json=False) for key in ('e_0','e_1','e_3')]
        if decode_content_shards(*parts).encode() != source['source']:
            raise ValueError('owner_bookmark/source_changed')
        if notes.observe(credentials, 'existing_bookmark_preflight') != before:
            raise ValueError('owner_bookmark/baseline_changed')
        save_refreshed_web_session(session, saved, web);saved = session.load()
        target = dict(id=row['bookmarkId'], sha256=digest(row))
        def read_current(grant):
            observed = notes.observe(grant, 'existing_bookmark_readback')
            record = observed['marks']['updated'].get(target['id'])
            if observed != before or record is None or digest(record) != target['sha256']:
                raise ValueError('owner_bookmark/account_changed')
            return target, observed
        adapter = SimpleNamespace(raw=source['source'].decode('utf-8'), first=point['chapter_offset'],
                                  source=SimpleNamespace(payload={'cookies': saved['cookies']}), read=read_current)
        phase = 'reader';result = verify(adapter, credentials, source, origin, target, args.lua_command)
        phase = 'final';web.verify_account()
        if (reading_position(web.request('progress_after', BASE + '/web/book/getProgress?bookId=' + book), book) != web_before
                or notes.observe(credentials, 'existing_bookmark_final') != before):
            raise ValueError('owner_bookmark/account_changed')
        save_refreshed_web_session(session, saved, web)
        report.update(result='EXISTING_BOOKMARK_OWNER_VERIFIED', screens=result['screens'],
                      native_web_source_matches=True, independent_source_point=True, navigation=True,
                      indicator_tap_verified=result['indicator_tap_verified'], offline_reopen=result['offline_reopen'],
                      original_cloud_state_unchanged=True, web_position_unchanged=True,
                      credential_file_audit=True, temporary_profiles_removed=True, installed_bytes_match=True)
    except (Exception, KeyboardInterrupt) as error:
        report.update(result='UNVERIFIED', phase=phase)
        if str(error) in {'owner_bookmark/no_eligible_sample', 'owner_bookmark/source_changed',
                          'owner_bookmark/baseline_changed', 'owner_bookmark/account_changed'}:
            report['reason'] = str(error)
        elif 'HTTP 401' in str(error):report['reason'] = 'auth_expired'
        elif 'HTTP 429' in str(error):report['reason'] = 'rate_limited'
    finally:
        if web:web.close()
        if saved:saved.clear()
        if credentials:credentials.clear()
    print(json.dumps(report));return int(report['result'] == 'UNVERIFIED')


if __name__ == '__main__':
    raise SystemExit(main())
