#!/usr/bin/env python3
"""Opt-in owner UI acceptance with file-backed caches and a fresh offline process.

Private account metadata and thumbnails exist only in an isolated Linux tmpfs
profile. Credentials remain in anonymous descriptors. Reports contain only
fixed fields/counts; no account-write or authorization-renewal route is allowed.
"""
import argparse
from datetime import datetime, timezone
import json
import re
import subprocess

from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore, StoreError, COOKIE_NAMES
from verify_native_metadata import NativeMetadataProbe, MetadataError, normalize_native
from verify_cb_metadata import valid_errors
from verify_cb_progress import cb_ids
from verify_eink_login import ProbeError
from verify_web_source_progress import WebSourceProbe
from verify_translation_preflight import save_refreshed_web_session
from verify_eink_renewal import book_id, safe_text

FRAME = b'\nWEREAD_PERSISTENT_UI_RESULT='
RUNNER_ERRORS = {'none', 'child_timeout', 'runner_exception', 'candidate_layout', 'input_limit', 'stage_unverified',
                 'persistent_ui_schema', 'persistent_ui_status', 'persistent_ui_flags', 'persistent_ui_counts',
                 'persistent_ui_requests', 'persistent_ui_offline_network', 'persistent_ui_progress',
                 'persistent_ui_incomplete', 'persistent_ui_frame'}
PHASES = {'init', 'shelf', 'home', 'book', 'audit', 'complete'}
FLAGS = {'anonymous_credentials', 'credential_file_audit', 'file_backed_sqlite',
         'bookstore_readback', 'transport_guard_selftest', 'progress_display_matches',
         'covers_visible', 'workers_reaped', 'preferences_readback'}
COUNTS = {'shelf_books': 5000, 'shelf_groups': 1000, 'painted_views': 4,
          'cover_gets': 48, 'progress_gets': 24, 'cover_cells': 24,
          'cover_retries': 48,
          'denied_kind': 3, 'denied_reason': 8, 'cover_redirects': 120,
          'cover_http_redirects': 120,
          'redirect_address_kind': 4,
          'progress_snapshots': 24, 'known_progress': 24,
          'failed_line': 1000, 'progress_http_status': 599,
          'progress_fetch_result': 4, 'progress_parse_result': 4,
          'progress_shape': 8,
          'profile_files_audited': 512, 'screenshots': 1, 'forbidden_requests': 512}
RUNNER_ERRORS |= {'persistent_ui_count_' + key for key in COUNTS}
RUNNER_ERRORS |= {'persistent_ui_coverage_schema','persistent_ui_coverage_incomplete'}
RUNNER_ERRORS |= {'persistent_ui_cb_scope','persistent_ui_cb_count'}
FULL_SHELF_LIMIT = 160
FULL_COUNTS = dict(COUNTS, shelf_books=FULL_SHELF_LIMIT, painted_views=322,
                   cover_gets=640, progress_gets=FULL_SHELF_LIMIT, cover_cells=FULL_SHELF_LIMIT,
                   cover_retries=640, cover_redirects=640, cover_http_redirects=640,
                   progress_snapshots=FULL_SHELF_LIMIT, known_progress=FULL_SHELF_LIMIT)
COVERAGE_COUNTS = {'reference_books', 'regular_books', 'public_accounts', 'forward_pages',
                   'reverse_pages', 'unique_cells', 'progress_eligible', 'cover_eligible'}
COVERAGE_FLAGS = {'partition_verified', 'reference_fields_match', 'page_cache_matches', 'boundaries_verified'}


def shelf_reference(value):
    """Independent, bounded display reference; never export this private map."""
    books=value.get('books') if isinstance(value,dict) else None
    if not isinstance(books,list) or not 1<=len(books)<=FULL_SHELF_LIMIT:
        raise ValueError('persistent_ui_shelf_reference')
    rows={}
    for row in books:
        identity=book_id(row.get('bookId')) if isinstance(row,dict) else None
        if not identity or identity in rows or not safe_text(row.get('title'),4096):
            raise ValueError('persistent_ui_shelf_reference')
        rows[identity]=dict(title=row['title'],author=row['author'] if safe_text(row.get('author'),4096) else '',
                            cover=row['cover'] if safe_text(row.get('cover'),8192) else '')
    return rows


class FullShelfMetadataProbe(NativeMetadataProbe):
    def request(self,stage,*args,**kwargs):
        value=super().request(stage,*args,**kwargs)
        if stage=='metadata_shelf':self.shelf_reference=shelf_reference(value)
        return value


class CbShelfMetadataProbe(FullShelfMetadataProbe):
    def inspect(self,credentials,sample_count):
        if type(sample_count) is not int or sample_count!=8:raise ValueError('persistent_ui_cb_scope')
        shelf=self.request('metadata_shelf','https://i.weread.qq.com/shelf/sync',credentials=credentials)
        identities=cb_ids(shelf);self.allowed_ids=set(identities)
        for identity in identities:
            source=self.request('metadata','https://i.weread.qq.com/book/info?bookId='+identity,credentials=credentials)
            valid_errors(source)
            self.samples.append(dict(book_id=identity,expected=normalize_native(source,identity)))
        return dict(shelf_book_count=len(shelf['books']))


def validate_stage(value, mode, *, all_shelf_pages=False,cb_metadata=False,metadata_books=1):
    if cb_metadata and (not all_shelf_pages or type(metadata_books) is not int or not 1<=metadata_books<=8):
        raise ValueError('persistent_ui_cb_scope')
    keys = FLAGS | set(COUNTS) | {'result', 'phase', 'mode', 'request_counts', 'paged_shelf'}
    if all_shelf_pages:keys |= {'shelf_coverage'}
    if cb_metadata:keys |= {'cb_metadata_books'}
    if not isinstance(value, dict) or set(value) != keys:
        raise ValueError('persistent_ui_schema')
    if (type(value['result']) is not str or value['result'] not in {'PASS', 'UNVERIFIED'}
            or type(value['phase']) is not str or value['phase'] not in PHASES
            or value['mode'] != mode or type(value['paged_shelf']) is not bool):
        raise ValueError('persistent_ui_status')
    if any(type(value[k]) is not bool for k in FLAGS):
        raise ValueError('persistent_ui_flags')
    limits=dict(FULL_COUNTS if all_shelf_pages else COUNTS)
    if cb_metadata:limits['painted_views']=328
    for key, maximum in limits.items():
        if type(value[key]) is not int or not 0 <= value[key] <= maximum:
            raise ValueError('persistent_ui_count_' + key)
    counts = value['request_counts']
    expected_native=[1,metadata_books if cb_metadata else 1]
    if (not isinstance(counts, list) or len(counts) != 2
            or any(type(n) is not int or not 0 <= n <= expected_native[index] for index,n in enumerate(counts))):
        raise ValueError('persistent_ui_requests')
    if mode == 'reopen' and (counts != [0, 0] or value['cover_gets'] or value['progress_gets']):
        raise ValueError('persistent_ui_offline_network')
    if value['known_progress'] > value['progress_snapshots']:
        raise ValueError('persistent_ui_progress')
    if value['cover_retries'] > value['cover_gets']:
        raise ValueError('persistent_ui_requests')
    if cb_metadata and (type(value['cb_metadata_books']) is not int or not 0<=value['cb_metadata_books']<=metadata_books
            or value['result']=='PASS' and value['cb_metadata_books']!=metadata_books):
        raise ValueError('persistent_ui_cb_count')
    expected_views=3+int(value['paged_shelf'])
    if all_shelf_pages:
        coverage=value['shelf_coverage']
        if (not isinstance(coverage,dict) or set(coverage)!=COVERAGE_COUNTS|COVERAGE_FLAGS
                or any(type(coverage[k]) is not int or not 0<=coverage[k]<=FULL_SHELF_LIMIT for k in COVERAGE_COUNTS)
                or any(type(coverage[k]) is not bool for k in COVERAGE_FLAGS)):
            raise ValueError('persistent_ui_coverage_schema')
        expected_views=coverage['forward_pages']+coverage['reverse_pages']+2
        tabs=int(coverage['regular_books']>0)+int(coverage['public_accounts']>0)
        if value['result']=='PASS' and (not all(coverage[k] for k in COVERAGE_FLAGS)
                or coverage['reference_books']!=value['shelf_books']
                or coverage['regular_books']+coverage['public_accounts']!=value['shelf_books']
                or coverage['unique_cells']!=value['shelf_books']
                or coverage['progress_eligible']!=value['progress_snapshots']
                or coverage['cover_eligible']!=value['cover_cells']
                or not tabs or coverage['forward_pages']<tabs
                or coverage['reverse_pages']!=(coverage['forward_pages']-tabs if mode=='reopen' else 0)
                or mode=='live' and value['progress_gets']!=coverage['progress_eligible']):
            raise ValueError('persistent_ui_coverage_incomplete')
    if cb_metadata:expected_views+=metadata_books-1
    if value['result'] == 'PASS' and (value['phase'] != 'complete' or not all(value[k] for k in FLAGS)
            or value['forbidden_requests'] or value['screenshots'] or value['failed_line'] or not value['shelf_books'] or not value['profile_files_audited']
            or value['painted_views'] != expected_views or not value['cover_cells']
            or not value['progress_snapshots'] or mode == 'live' and (counts != expected_native
                or not value['cover_gets'] or not value['progress_gets'])):
        raise ValueError('persistent_ui_incomplete')
    return value


def decode_stage(raw, mode, *, all_shelf_pages=False,cb_metadata=False,metadata_books=1):
    if not isinstance(raw, bytes) or len(raw) > 2 * 1024 * 1024 or raw.count(FRAME) != 1:
        raise ValueError('persistent_ui_frame')
    return validate_stage(json.loads(raw.split(FRAME)[1]), mode,all_shelf_pages=all_shelf_pages,
                          cb_metadata=cb_metadata,metadata_books=metadata_books)


def decode_result(raw, *, all_shelf_pages=False,cb_metadata=False,metadata_books=1):
    if not isinstance(raw, bytes) or len(raw) > 65536 or raw.count(FRAME) != 1:
        raise ValueError('persistent_ui_frame')
    value = json.loads(raw.split(FRAME)[1])
    if (not isinstance(value, dict) or set(value) != {'result', 'tmpfs_profile', 'profile_removed', 'stages', 'runner_error'}
            or type(value['tmpfs_profile']) is not bool or type(value['profile_removed']) is not bool
            or value['result'] not in ('PASS', 'UNVERIFIED') or not isinstance(value['stages'], list)
            or len(value['stages']) > 2 or type(value['runner_error']) is not str or value['runner_error'] not in RUNNER_ERRORS):
        raise ValueError('persistent_ui_runner_schema')
    for mode, stage in zip(('live', 'reopen'), value['stages']):
        validate_stage(stage, mode,all_shelf_pages=all_shelf_pages,cb_metadata=cb_metadata,metadata_books=metadata_books)
    if value['result'] == 'PASS' and (value['runner_error'] != 'none' or not value['tmpfs_profile'] or not value['profile_removed']
            or len(value['stages']) != 2 or any(s['result'] != 'PASS' for s in value['stages'])
            or any(value['stages'][0][k] != value['stages'][1][k]
                   for k in ('shelf_books', 'shelf_groups', 'progress_snapshots', 'known_progress', 'cover_cells'))):
        raise ValueError('persistent_ui_runner_incomplete')
    if value['result']=='PASS' and all_shelf_pages:
        for key in COVERAGE_COUNTS-{'reverse_pages'}:
            if value['stages'][0]['shelf_coverage'][key]!=value['stages'][1]['shelf_coverage'][key]:
                raise ValueError('persistent_ui_coverage_incomplete')
    return value


def verified_web_snapshot(store, saved):
    """Verify the Web owner and retain any verified cookie rotation first."""
    web = WebSourceProbe()
    web.vid = saved['vid']
    for key, value in saved['cookies'].items():
        web.set_cookie(key, value)
    web.verify_account()
    rotated = save_refreshed_web_session(store, saved, web)
    cookies = {c.name: c.value for c in web.cookies if c.name in COOKIE_NAMES
               and c.domain in ('.weread.qq.com', 'weread.qq.com') and c.path == '/'}
    return cookies, rotated


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--all-shelf-pages', action='store_true',help='opt-in full shelf up to 160 entries and reverse offline paging')
    parser.add_argument('--cb-metadata',action='store_true',help='also verify every selected CB detail and its offline file cache')
    parser.add_argument('--lua-command', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if bool(args.saved_session) != bool(args.lua_command):
        parser.error('pair --saved-session and --lua-command; put --lua-command last')
    if args.all_shelf_pages and not args.saved_session:parser.error('--all-shelf-pages requires --saved-session')
    if args.cb_metadata and not args.all_shelf_pages:parser.error('--cb-metadata requires --all-shelf-pages')
    report = dict(result='OFFLINE_ONLY', checked_at=datetime.now(timezone.utc).isoformat(),
                  credentials_written_to_persistent_files=False, private_data_on_regular_disk=False,
                  account_data_writes_attempted=0, authentication_posts_attempted=0, screenshots=0)
    credentials = probe = saved = None
    try:
        if args.saved_session:
            store = SessionStore()
            saved = store.load()
            credentials = NativeSessionStore().load(saved['vid'])
            probe = CbShelfMetadataProbe() if args.cb_metadata else FullShelfMetadataProbe() if args.all_shelf_pages else NativeMetadataProbe()
            baseline = probe.inspect(credentials, 8 if args.cb_metadata else 1)
            sample = probe.samples[0]
            cookies, rotated = verified_web_snapshot(store, saved)
            report['web_cookie_rotation_saved'] = rotated
            payload = dict(credentials=credentials, cookies=cookies,
                           book_id=sample['book_id'], expected_metadata=sample['expected'],
                           shelf_books=baseline['shelf_book_count'])
            if args.all_shelf_pages:
                payload.update(all_shelf_pages=True,expected_shelf=probe.shelf_reference)
            if args.cb_metadata:
                payload.update(cb_metadata=True,metadata_samples=[dict(book_id=row['book_id'],expected_metadata=row['expected']) for row in probe.samples])
            encoded = json.dumps(payload, ensure_ascii=False).encode()
            if len(encoded) > 256 * 1024:
                raise ValueError('persistent_ui_input_limit')
            child = subprocess.run(args.lua_command, input=encoded, capture_output=True, timeout=1280 if args.all_shelf_pages else 320)
            domains = re.findall(rb'(?m)^WEREAD_PUBLIC_COVER_DOMAIN=([a-z-]{1,63}\.[a-z]{2,12})$', child.stderr)
            if domains:
                report['blocked_image_domains'] = sorted({d.decode('ascii') for d in domains})
            value = decode_result(child.stdout,all_shelf_pages=args.all_shelf_pages,cb_metadata=args.cb_metadata,metadata_books=len(probe.samples))
            report.update(ui=value, python_preflight_gets=2+len(probe.samples), same_owner_verified=True)
            if child.returncode or value['result'] != 'PASS':
                raise ValueError('persistent_ui_unverified')
            report['result'] = 'OWNER_FILE_BACKED_UI_READ_VERIFIED'
    except (StoreError, ProbeError, MetadataError):
        report.update(result='UNVERIFIED', reason='owner_native_preflight_failed')
    except (ValueError, subprocess.TimeoutExpired):
        report.update(result='UNVERIFIED', reason='persistent_ui_unverified')
    except Exception:
        report.update(result='UNVERIFIED', reason='persistent_ui_probe_failed')
    finally:
        if probe:
            report['preflight_stages'] = [
                {key: row[key] for key in ('stage', 'status', 'error_code')
                 if key in row and (key == 'stage' or type(row[key]) is int)}
                for row in getattr(probe, 'report', {}).get('stages', [])
                if isinstance(row, dict) and row.get('stage') in ('metadata_shelf', 'metadata')]
        if credentials:
            credentials.clear()
        if saved:
            saved.clear()
        if probe:
            probe.samples.clear()
            if hasattr(probe,'shelf_reference'):probe.shelf_reference.clear()
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report['result'] in ('OFFLINE_ONLY', 'OWNER_FILE_BACKED_UI_READ_VERIFIED') else 1


if __name__ == '__main__':
    raise SystemExit(main())
