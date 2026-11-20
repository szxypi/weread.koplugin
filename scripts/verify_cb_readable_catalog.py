#!/usr/bin/env python3
"""Compare real imported-book catalog filtering in KOReader, read-only.

Offline unless explicitly requested. IDs, catalog rows and credentials are
kept in memory and private pipes; the report contains only counts and flags.
"""
import argparse
import json
import math
import resource
import subprocess

from fetch_weread_epub import normalize_chapter_infos
from secure_weread_session import SessionStore
from verify_cb_metadata import CbMetadataWebProbe, validate_catalog
from verify_cb_progress import cb_ids
from verify_cb_native_time_guarded_dry import trusted_command
from verify_web_source_progress import BASE


def readable(row):
    if not isinstance(row, dict): raise ValueError('readable_catalog/row')
    count = row.get('wordCount')
    if count is None or count is False: count = 0
    if isinstance(count, bool) or not isinstance(count, (str, int, float)):
        raise ValueError('readable_catalog/word_count')
    try: number = float(count)
    except ValueError: raise ValueError('readable_catalog/word_count') from None
    if not math.isfinite(number): raise ValueError('readable_catalog/word_count')
    title = row.get('title')
    if title is None or title is False: title = ''
    if not isinstance(title, str): raise ValueError('readable_catalog/title')
    return number > 0 and title != '封面'


def runtime(samples):
    prefix = trusted_command()[:6]
    prefix[4] = '/validation/runtime/lib/koreader'
    command = prefix + ['env', 'LUA_PATH=/source/?.lua;/source/?/init.lua;./?.lua;./?/init.lua;;',
                        'LD_LIBRARY_PATH=/validation/runtime/lib/koreader/libs', './luajit',
                        '/source/spec/koreader/cb_catalog_readable_probe.lua']
    encoded = json.dumps({'samples': samples}, ensure_ascii=False, separators=(',', ':')).encode()
    if len(encoded) > 8 * 1024 * 1024: raise ValueError('readable_catalog/size')
    child = subprocess.run(command, input=encoded, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=120)
    marker = b'\nWEREAD_CB_READABLE_CATALOG='
    if child.returncode or len(child.stdout) > 65536 or child.stdout.count(marker) != 1:
        raise ValueError('readable_catalog/runtime')
    return json.loads(child.stdout.split(marker, 1)[1])


def inspect(saved, same, *, factory=CbMetadataWebProbe, compare=runtime):
    if same() is not True: raise ValueError('readable_catalog/session')
    def probe():
        value = factory(); value.vid = saved['vid']
        for name, cookie in saved['cookies'].items(): value.set_cookie(name, cookie)
        return value
    def shelf():
        web = probe()
        try:
            web.verify_account(); return cb_ids(web.request('shelf', BASE + '/web/shelf/sync'))
        finally: web.close()
    ids = shelf(); samples = []
    for identity in ids:
        if same() is not True: raise ValueError('readable_catalog/session')
        web = probe()
        try:
            web.allowed = {identity}; web.book_id = web.catalog_book = identity
            web.verify_account()
            value = web.request('catalog_before', BASE + '/web/book/chapterInfos', {'bookIds': [identity]})
            validate_catalog(value, identity); _record, rows = normalize_chapter_infos(value, identity)
            samples.append({'rows': rows, 'expected': [readable(row) for row in rows]})
        finally: web.close()
    expected = dict(matches=True, catalogs=len(samples), total_rows=sum(len(item['rows']) for item in samples),
                    excluded_rows=sum(sum(not flag for flag in item['expected']) for item in samples))
    if compare(samples) != expected or same() is not True or shelf() != ids:
        raise ValueError('readable_catalog/changed')
    return expected


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('--saved-session', action='store_true')
    args = parser.parse_args(argv)
    report = dict(result='OFFLINE_ONLY', account_data_posts=0, authentication_posts=0, private_data_saved=False)
    if not args.saved_session:
        print(json.dumps(report)); return 0
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0)); saved = None
    try:
        store = SessionStore(); saved = store.load()
        result = inspect(saved, lambda: store.load() == saved)
        report.update(result='READ_ONLY_CATALOG_VERIFIED', catalogs=result['catalogs'], total_rows=result['total_rows'],
                      excluded_rows=result['excluded_rows'], koreader_matches=True, shelf_unchanged=True)
    except Exception:
        report['result'] = 'UNVERIFIED'
    finally:
        if saved: saved.clear()
    print(json.dumps(report)); return int(report['result'] != 'READ_ONLY_CATALOG_VERIFIED')


if __name__ == '__main__': raise SystemExit(main())
