#!/usr/bin/env python3
"""Read-only owner acceptance for a small, bounded native chapter batch."""
import argparse
import hashlib
import json
import resource
import subprocess
from urllib.parse import urlencode

from native_chapter_package import password, read
from native_chapter_remote_reference import search_token
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from shelf_flag_change_contract import state_hash
from verify_eink_login import BASE
from verify_native_book_catalog import expected
from verify_native_chapter_package import ChapterProbe
from verify_native_discovery import identity
from verify_owner_reading import reading_position
from verify_translation_preflight import TranslationError, catalog_body
from verify_web_source_progress import BASE as WEB_BASE, WebSourceProbe

MARKER = b'\nWEREAD_BATCH_OWNER_RUN='


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--full-shelf', action='store_true')
    args = parser.parse_args()
    if not args.saved_session:
        parser.error('explicit --saved-session is required for account reads')
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    report = dict(result='UNVERIFIED', account_data_writes=0, authentication_posts=0,
                  credentials_written_to_files=False)
    saved = credentials = web = None
    phase = 'credentials'
    try:
        saved = SessionStore().load()
        credentials = NativeSessionStore().load(saved['vid'])
        api = ChapterProbe()
        phase = 'shelf'
        shelf = api.request('shelf', BASE+'/shelf/sync', credentials=credentials)
        before = state_hash(shelf)
        ids = []
        for row in shelf.get('books', []):
            key = identity(row.get('bookId')) if isinstance(row, dict) else None
            if key and key not in ids: ids.append(key)
            if len(ids) == 8: break
        if not ids: raise ValueError('no_books')
        api.allowed = set(ids)
        samples = []
        phase = 'catalog'
        for key in ids:
            info = api.request('book', BASE+'/book/info?'+urlencode({'bookId':key}), credentials=credentials)
            raw = api.request('catalog', BASE+'/book/chapterInfos', catalog_body(key), credentials=credentials)
            try:
                model = expected(raw, key, info)
            except (ValueError, KeyError, TypeError, TranslationError):
                continue
            available = [row for row in model['chapters'] if row['downloadable']]
            if 1 <= len(available) <= 8 and len(model['chapters']) <= 200:
                samples.append((len(available), key, model, available))
        if not samples: raise ValueError('no_small_sample')
        _, book_id, model, available = min(samples, key=lambda value: (value[0], len(value[2]['chapters'])))
        phase = 'web_baseline'
        web = WebSourceProbe();web.vid = saved['vid'];web.book_id = book_id
        for key, value in saved['cookies'].items(): web.set_cookie(key, value)
        web.verify_account()
        before_web = reading_position(web.request('progress_before', WEB_BASE+'/web/book/getProgress?bookId='+book_id),
                                      book_id, allow_unstarted=True)
        phase = 'source'
        sources = {}
        for row in available:
            uid = row['chapterUid']
            fields = dict(bookId=book_id, chapters='0,'+uid, bookType='epub', bookVersion=model['version'],
                pf='wechat_wx-2001-android-100-weread', pfkey='pfKey', zoneId=1, quote='', release=1,
                stopAutoPayWhenBNE=1, preload=2, preview=0, offline=1)
            probe = ChapterProbe()
            probe.archive_url = BASE+'/book/chapterdownload?'+urlencode(fields)
            data, envelope = probe.download(probe.archive_url, credentials)
            source = read(data, password(envelope, credentials['vid']), uid)['source']
            item = dict(sha256=hashlib.sha256(source).hexdigest())
            try: item['token'] = search_token(source)
            except ValueError: pass
            sources[uid] = item
        payload = dict(credentials=credentials, book_id=book_id, version=model['version'],
                       total=len(model['chapters']), sources=sources)
        if args.full_shelf:
            projected, seen = [], set()
            def safe_text(value):
                if (isinstance(value, str) and len(value.encode()) <= 2048
                        and not any(ord(char) < 32 or ord(char) == 127 for char in value)):
                    return value
                return ''
            for row in shelf.get('books', []):
                key = identity(row.get('bookId')) if isinstance(row, dict) else None
                if key and key not in seen:
                    seen.add(key)
                    projected.append(dict(bookId=key, title=safe_text(row.get('title')),
                                          author=safe_text(row.get('author'))))
            if book_id not in seen or not 1 <= len(projected) <= 5000: raise ValueError('shelf_projection')
            payload.update(full_shelf=True, shelf_books=projected)
        encoded = json.dumps(payload, ensure_ascii=False).encode()
        if len(encoded)>262144: raise ValueError('input_limit')
        phase = 'native_runner'
        child = subprocess.run(['docker', 'exec', '-i', 'weread-validation', 'python3',
                                '/source/scripts/run_native_direct_batch_owner.py'],
                               input=encoded, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, timeout=900)
        if len(child.stdout)>65536 or child.stdout.count(MARKER)!=1: raise ValueError('runner')
        result = json.loads(child.stdout.split(MARKER, 1)[1].splitlines()[0])
        if child.returncode or result.get('result')!='PASS':
            if result.get('phase') in {'input','online','repeat','offline','audit'}: report['runner_phase']=result['phase']
            if type(result.get('probe_line')) is int and 0 <= result['probe_line'] <= 10000:
                report['runner_line'] = result['probe_line']
            if result.get('reason') in {'auth_expired','rate_limited','session_changed','catalog_changed',
                                       'unavailable','not_entitled','storage','invalid_source','invalid'}:
                report['reason'] = result['reason']
            raise ValueError('runner')
        if (result.get('chapters')!=len(available) or result.get('unavailable')!=len(model['chapters'])-len(available)
                or result.get('screen_sizes')!=2 or any(result.get(key) is not True for key in (
                    'profile_removed','source_matches','repeat_skipped','offline_render','network_blocked',
                    'credential_file_audit','installed_bytes_match'))):
            raise ValueError('runner_result')
        if args.full_shelf and (result.get('full_plugin') is not True or result.get('offline_reader') is not True
                                or result.get('shelf_count')!=len(projected)):
            raise ValueError('shelf_result')
        phase = 'final_check'
        for _ in range(2):
            if state_hash(api.request('shelf', BASE+'/shelf/sync', credentials=credentials)) != before:
                raise ValueError('shelf_changed')
            progress = reading_position(web.request('progress_after', WEB_BASE+'/web/book/getProgress?bookId='+book_id),
                                        book_id, allow_unstarted=True)
            if progress != before_web: raise ValueError('progress_changed')
        report.update(result='PASS', chapters=len(available), unavailable=len(model['chapters'])-len(available),
            rendered_tokens=sum('token' in item for item in sources.values()), screen_sizes=2,
            shelf_members_flags_groups_unchanged=True, web_position_unchanged=True,
            source_matches=True, repeat_skipped=True, offline_render=True, network_blocked=True,
            credential_file_audit=True, installed_bytes_match=True, profile_removed=True,
            missing_images_by_size=[row['missing'] for row in result['samples']])
        if args.full_shelf:
            report.pop('rendered_tokens')
            report.update(full_plugin=True, numeric_shelf_books=len(projected), offline_reader_opened=True,
                offline_reader_chapters=1, other_cached_chapters_verified=len(available)-1,
                reader_text_checked_by_size=[row['reader_text_checked'] for row in result['samples']])
    except (Exception, KeyboardInterrupt) as error:
        report['phase'] = phase
        if 'HTTP 401' in str(error): report['reason'] = 'auth_expired'
        elif 'HTTP 429' in str(error): report['reason'] = 'rate_limited'
    finally:
        if web: web.cookies.clear()
        if saved: saved.clear()
        if credentials: credentials.clear()
    print(json.dumps(report))
    return int(report['result']!='PASS')


if __name__ == '__main__':
    raise SystemExit(main())
