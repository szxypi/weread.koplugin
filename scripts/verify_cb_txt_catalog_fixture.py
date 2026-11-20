#!/usr/bin/env python3
"""One self-authored TXT import, read-only catalog/source inspection, cleanup.

Offline by default. The import uses a distinct, durable one-shot journal and
only the just-imported fixture may be removed. Private data stays in memory.
"""
import argparse
import hashlib
import json
import math
import resource
import subprocess
import tempfile
import time
from pathlib import Path

from cloud_group_nonempty_journal import Journal as GroupJournal
from fetch_weread_epub import decode_content_shards, make_content_params, normalize_chapter_infos, reader_url_for
from personal_upload_trial import Journal as BaseJournal, check, hash_value, projection, validate
from secure_native_session import NativeSessionStore, project_lock
from secure_weread_session import ACCOUNT, COOKIE_NAMES, MacKeychain, SessionStore
from verify_cb_metadata import CbMetadataWebProbe, CbNativeMetadataProbe, validate_catalog
from verify_cb_progress import cb_id, cb_ids
from verify_cb_reading import CbReadingProbe, baseline_position, txt_marker
from verify_cb_txt_fixture import Receipt, guarded_previous
from verify_cb_txt_version_fixture import category, fields
from verify_cb_native_time_guarded_dry import trusted_command
from verify_eink_login import BASE as NATIVE_BASE, NativeProbe
from verify_personal_upload_trial import Probe
from verify_reader_context import project as reader_context
from verify_shelf_flags import WebFlagsProbe
from verify_synthetic_epub_upload import run
from verify_web_source_progress import BASE, identifier, versions
from urllib.parse import urlencode

MARKER = 'Unique self-authored catalog verification passage for KOReader.'
BODY = ('\n'.join(f'第{i}章 合成目录验证\n' + '\n'.join(
    f'{MARKER} Chapter {i}, paragraph {j}: 测试目录、章节和原生阅读。' for j in range(1, 31))
    for i in range(1, 4)) + '\n').encode('utf-8')
BODY_HASH = hashlib.sha256(BODY).hexdigest()


def validate_plan(plan):
    validate(plan)
    if plan['body_sha256'] != BODY_HASH: raise ValueError('cb_txt_catalog/fixture')
    return plan


def prepare_plan(credentials, shelf, name):
    data = projection(shelf); data.pop('present')
    return validate_plan(dict(owner=credentials['vid'], name=name, body_sha256=BODY_HASH,
                              grant_sha256=hash_value(credentials), **data))


def check_plan(plan, credentials, shelf, target=None, expected=False):
    return check(plan, credentials, shelf, target, expected, validator=validate_plan)


class Journal(BaseJournal):
    def __init__(self, backend=None, lock=None):
        if backend is None:
            backend = MacKeychain(service='org.codex.weread.cb-txt-catalog-fixture-v1', account=ACCOUNT)
            path = Path(tempfile.gettempdir()) / ('codex-cb-txt-catalog-fixture-' + ACCOUNT + '.lock')
            lock = lock or (lambda: project_lock(path))
        super().__init__(backend=backend, lock=lock, validator=validate_plan)


def catalog_counts(rows):
    if not isinstance(rows, list) or not 1 <= len(rows) <= 5000: raise ValueError('cb_txt_catalog/rows')
    result = dict(catalog_chapters=len(rows), count_missing=0, count_zero=0, count_positive=0, count_invalid=0)
    for row in rows:
        if not isinstance(row, dict): raise ValueError('cb_txt_catalog/rows')
        if 'wordCount' not in row or row['wordCount'] is None: result['count_missing'] += 1
        elif (type(row['wordCount']) not in (int, float) or not math.isfinite(row['wordCount'])
              or row['wordCount'] < 0): result['count_invalid'] += 1
        elif row['wordCount'] == 0: result['count_zero'] += 1
        else: result['count_positive'] += 1
    return result


def read_fixture(saved, target, summary, *, factory=CbReadingProbe, chapter_uid=None, expected_catalog=None,
                 verify_source=None, expected_version=None):
    if not cb_id(target): raise ValueError('cb_txt_catalog/target')
    web = factory(); web.vid = saved['vid']; web.allowed = {target}; web.book_id = target
    try:
        for name, value in saved['cookies'].items(): web.set_cookie(name, value)
        web.verify_account()
        before = web.request('catalog_before', BASE + '/web/book/chapterInfos', {'bookIds': [target]})
        validate_catalog(before, target); record, rows = normalize_chapter_infos(before, target)
        if expected_catalog is not None:
            validate_catalog(expected_catalog, target); expected_record, expected_rows = normalize_chapter_infos(expected_catalog, target)
            if rows != expected_rows or versions(record) != versions(expected_record): return False
        summary.update(catalog_counts(rows)); summary['catalog_observed'] = True
        baseline = baseline_position(web.request('progress_before', BASE + '/web/book/getProgress?bookId=' + target), target)
        choices = [row for row in rows if str(row.get('title') or '') != '封面']
        if chapter_uid is not None:
            selected = identifier(chapter_uid)
            choices = [row for row in choices if identifier(row.get('chapterUid')) == selected]
            if len(choices) != 1: return False
        elif baseline['chapter'] != '0':
            choices = [row for row in choices if identifier(row.get('chapterUid')) == baseline['chapter']]
        if not choices: return False
        chapter = identifier(choices[0].get('chapterUid')); web.chapter = chapter
        context = reader_context({'book_id': target}, web.request('reader', reader_url_for(target, chapter), as_json=False))
        if identifier(context['current_chapter'].get('chapterUid')) != chapter: return False
        web.psvts = context['psvts']
        def read(name):
            return web.request(name, BASE + '/web/book/chapter/' + name,
                               make_content_params(target, chapter, web.psvts, sc=1), as_json=False)
        first = read('e_0')
        if txt_marker(first, target, chapter):
            web.txt_scope = True; source = decode_content_shards(read('t_0'), read('t_1'), ''); kind = 'web_txt'
        else:
            source = decode_content_shards(first, read('e_1'), read('e_3')); kind = 'web_xhtml'
        after = web.request('catalog_after', BASE + '/web/book/chapterInfos', {'bookIds': [target]})
        validate_catalog(after, target); later, later_rows = normalize_chapter_infos(after, target)
        position = baseline_position(web.request('progress_after', BASE + '/web/book/getProgress?bookId=' + target), target)
        web.verify_account()
        stable = rows == later_rows and versions(record) == versions(later) and baseline == position
        summary.update(source_format=kind, source_marker_found=MARKER in source,
                       catalog_and_position_unchanged=stable)
        if stable and MARKER in source and verify_source is not None:
            index=choices[0].get('chapterIdx'); encoded=source.encode()
            if kind!='web_xhtml' or type(index) is not int or not 0<=index<=1000000: return False
            cookies={cookie.name:cookie.value for cookie in web.cookies if cookie.name in COOKIE_NAMES
                     and cookie.domain in ('.weread.qq.com','weread.qq.com') and cookie.path=='/'}
            if cookies.get('wr_vid')!=saved['vid'] or not cookies.get('wr_skey'): return False
            expected=dict(book_id=target,chapter_uid=chapter,chapter_idx=index,
                          raw_sha256=hashlib.sha256(encoded).hexdigest(),raw_bytes=len(encoded))
            if verify_source(expected,dict(vid=saved['vid'],cookies=cookies),expected_version) is not True: return False
            summary['koreader_source_match']=True
        return stable and MARKER in source
    finally:
        web.samples.clear(); web.close()


def execute(probe, journal, receipt, credentials, current, read_content, old_guard, *, apply=False, sleep=time.sleep, now=time.time):
    if receipt.backend.load() is not None or old_guard() is not True: raise ValueError('cb_txt_catalog/guard')
    def cleanup_gate(_journal, _receipt, _plan, target):
        old = GroupJournal(); before = old.read()
        if not before[0] or target == before[0]['target'] or old_guard() is not True: return False
        return old.read() == before
    return run(probe, journal, credentials, current, read_content, apply=apply, sleep=sleep, now=now,
               fixture_builder=lambda: BODY, prepare_plan=prepare_plan, check_plan=check_plan,
               fixture_extension='txt', readback_tries=7, notify_receipt=receipt.record, cleanup_gate=cleanup_gate)


def compare_runtime(target, catalog, book_version):
    prefix = trusted_command()[:6]; prefix[4] = '/validation/runtime/lib/koreader'
    command = prefix + ['env', 'LUA_PATH=/source/?.lua;/source/?/init.lua;./?.lua;./?/init.lua;;',
                        'LD_LIBRARY_PATH=/validation/runtime/lib/koreader/libs', './luajit',
                        '/source/spec/koreader/cb_txt_catalog_fixture_probe.lua']
    encoded = json.dumps(dict(book=target, catalog=catalog, version=book_version), ensure_ascii=False).encode()
    if len(encoded) > 8 * 1024 * 1024: raise ValueError('cb_txt_catalog/size')
    child = subprocess.run(command, input=encoded, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=120)
    marker = b'\nWEREAD_CB_TXT_CATALOG_FIXTURE='
    if child.returncode or len(child.stdout) > 65536 or child.stdout.count(marker) != 1:
        raise ValueError('cb_txt_catalog/runtime')
    return json.loads(child.stdout.split(marker, 1)[1])


def compare_source_runtime(expected, saved, book_version):
    prefix=trusted_command()[:6];prefix[4]='/validation/runtime/lib/koreader'
    command=prefix+['env','SDL_VIDEODRIVER=dummy','LUA_PATH=/source/?.lua;/source/?/init.lua;./?.lua;./?/init.lua;;',
                    'LD_LIBRARY_PATH=/validation/runtime/lib/koreader/libs','./luajit',
                    '/source/spec/koreader/cb_source_currentness_probe.lua','/source']
    encoded=json.dumps(dict(expected=expected,vid=saved['vid'],cookies=saved['cookies'],book_version=book_version)).encode()
    if len(encoded)>65536: raise ValueError('cb_txt_catalog/size')
    child=subprocess.run(command,input=encoded,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=120)
    marker=b'\nWEREAD_CB_SOURCE_CURRENTNESS='
    if child.returncode or len(child.stdout)>65536 or child.stdout.count(marker)!=1:
        raise ValueError('cb_txt_catalog/source_runtime')
    value=json.loads(child.stdout.split(marker,1)[1].splitlines()[0])
    return value==dict(matched=True,requests=8,upload_disabled=True,numeric_gate_preserved=True)


def removed_fixture(saved, grant, current, journal, receipt, *, web_factory=CbMetadataWebProbe,
                    native_factory=CbNativeMetadataProbe, shelf_factory=NativeProbe, compare=compare_runtime,
                    source_reader=read_fixture, compare_source=compare_source_runtime, all_sources=False):
    state, token = journal.read(); raw = receipt.backend.load()
    value = json.loads(raw) if isinstance(raw, bytes) and len(raw) <= 8192 else None
    if (not state or state['phase'] != 'restored' or not token or not isinstance(value, dict)
            or set(value) != {'schema', 'owner', 'attempt', 'target', 'plan_sha256'} or value['schema'] != 1
            or value['owner'] != saved['vid'] or value['owner'] != state['plan']['owner']
            or value['attempt'] != state['attempt'] or value['target'] != state['target']
            or value['plan_sha256'] != hash_value(state['plan']) or hash_value(grant) != state['plan']['grant_sha256']
            or not cb_id(state['target']) or current() is not True): raise ValueError('cb_txt_catalog/receipt')
    target = state['target']; observations = []
    for _i in range(2):
        web = web_factory(); web.vid = saved['vid']; web.allowed = {target}; web.book_id = web.catalog_book = target
        try:
            for name, cookie in saved['cookies'].items(): web.set_cookie(name, cookie)
            web.verify_account()
            if target in cb_ids(web.request('shelf', BASE + '/web/shelf/sync')): raise ValueError('cb_txt_catalog/shelf')
            catalog = web.request('catalog_before', BASE + '/web/book/chapterInfos', {'bookIds': [target]})
            validate_catalog(catalog, target); record, chapters = normalize_chapter_infos(catalog, target)
            native = native_factory(); native.allowed_ids = {target}
            info = native.request('metadata', NATIVE_BASE + '/book/info?' + urlencode({'bookId': target}), credentials=grant)
            shelf = shelf_factory().request('shelf_full', NATIVE_BASE + '/shelf/sync', credentials=grant)
            if info.get('bookId') != target or target in cb_ids(shelf) or current() is not True:
                raise ValueError('cb_txt_catalog/shelf')
            observations.append((catalog, chapters, fields(record), fields(record.get('book', {})), fields(info)))
        finally: web.close()
    if observations[0] != observations[1] or journal.read() != (state, token) or receipt.backend.load() != raw:
        raise ValueError('cb_txt_catalog/changed')
    catalog, chapters, root, nested, native_fields = observations[0]; combined = root + nested
    if (category(native_fields) != 'positive' or category(combined) != 'positive'
            or native_fields[0][1] != combined[0][1]): raise ValueError('cb_txt_catalog/version')
    expected = dict(chapters=len(chapters), matching_version=True, chapter_indexes_valid=True, unversioned_rejected=True)
    if compare(target, catalog, native_fields[0][1]) != expected or current() is not True:
        raise ValueError('cb_txt_catalog/runtime')
    result = dict(catalog_chapters=len(chapters), native_version=category(native_fields),
                web_root_version=category(root), web_book_version=category(nested),
                web_and_native_positive_match=bool(category(native_fields) == 'positive' and category(combined) == 'positive'
                                                   and native_fields[0][1] == combined[0][1]),
                independent_reads=2, both_shelves_exclude_fixture=True, koreader_catalog_and_version_match=True)
    if all_sources:
        formats = {'web_txt': 0, 'web_xhtml': 0}
        for chapter in chapters:
            if current() is not True: raise ValueError('cb_txt_catalog/session')
            sample = {}
            if not source_reader(saved, target, sample, chapter_uid=identifier(chapter.get('chapterUid')),
                                 expected_catalog=catalog, verify_source=compare_source,
                                 expected_version=native_fields[0][1]):
                raise ValueError('cb_txt_catalog/source')
            kind = sample.get('source_format')
            if kind not in formats or sample.get('source_marker_found') is not True or sample.get('koreader_source_match') is not True:
                raise ValueError('cb_txt_catalog/source')
            formats[kind] += 1
        if current() is not True: raise ValueError('cb_txt_catalog/session')
        result.update(chapter_sources_checked=sum(formats.values()), source_formats=formats,
                      koreader_versioned_sources_match=True)
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true'); parser.add_argument('--apply', action='store_true')
    parser.add_argument('--inspect-removed', action='store_true')
    parser.add_argument('--all-sources', action='store_true')
    args = parser.parse_args(argv)
    if ((args.apply or args.inspect_removed) and not args.saved_session or args.apply and args.inspect_removed
            or args.all_sources and not args.inspect_removed):
        parser.error('online actions require --saved-session and cannot be combined')
    report = dict(result='OFFLINE_ONLY', account_data_writes=0, authentication_posts=0, private_data_saved=False)
    if not args.saved_session:
        print(json.dumps(report)); return 0
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0)); saved = grant = web = None; summary = {}
    try:
        session = SessionStore(); saved = session.load(); native_store = NativeSessionStore(); grant = native_store.load(saved['vid'])
        def current(value=None):
            return session.load() == saved and native_store.load(saved['vid']) == grant and (value is None or value == grant)
        web = WebFlagsProbe(); web.vid = saved['vid']
        for name, value in saved['cookies'].items(): web.set_cookie(name, value)
        web.verify_account(); native = NativeProbe()
        old_guard = lambda: guarded_previous(grant, current, native, web)
        journal = Journal(); receipt = Receipt(MacKeychain(service='org.codex.weread.cb-txt-catalog-target-v1', account=ACCOUNT))
        if args.inspect_removed:
            if old_guard() is not True: raise ValueError('cb_txt_catalog/guard')
            report.update(removed_fixture(saved, grant, current, journal, receipt, all_sources=args.all_sources),
                          result='REMOVED_FIXTURE_READ_VERIFIED')
        else:
            report = execute(Probe(journal, current), journal, receipt, grant, current,
                             lambda target: read_fixture(saved, target, summary), old_guard, apply=args.apply)
            report.update(summary)
            report['account_data_writes'] = report['notify_posts'] + report['cleanup_posts']
        report['old_group_guard_passed_after'] = old_guard()
        report['existing_book_writes'] = 0; report['private_data_saved'] = False
    except Exception:
        report = dict(result='UNVERIFIED', account_data_writes=None if args.apply else 0, authentication_posts=0,
                      existing_book_writes=0, private_data_saved=False)
    finally:
        if web: web.close()
        if grant: grant.clear()
        if saved: saved.clear()
    print(json.dumps(report))
    return int(report['result'] not in ('READ_ONLY_PREVIEW', 'TXT_IMPORT_AND_SOURCE_VERIFIED',
                                        'TXT_IMPORTED_SOURCE_UNVERIFIED', 'REMOVED_FIXTURE_READ_VERIFIED'))


if __name__ == '__main__': raise SystemExit(main())
