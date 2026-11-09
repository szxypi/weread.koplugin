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
from verify_native_metadata import NativeMetadataProbe, MetadataError
from verify_eink_login import ProbeError
from verify_web_source_progress import WebSourceProbe
from verify_translation_preflight import save_refreshed_web_session

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


def validate_stage(value, mode):
    keys = FLAGS | set(COUNTS) | {'result', 'phase', 'mode', 'request_counts', 'paged_shelf'}
    if not isinstance(value, dict) or set(value) != keys:
        raise ValueError('persistent_ui_schema')
    if (type(value['result']) is not str or value['result'] not in {'PASS', 'UNVERIFIED'}
            or type(value['phase']) is not str or value['phase'] not in PHASES
            or value['mode'] != mode or type(value['paged_shelf']) is not bool):
        raise ValueError('persistent_ui_status')
    if any(type(value[k]) is not bool for k in FLAGS):
        raise ValueError('persistent_ui_flags')
    for key, maximum in COUNTS.items():
        if type(value[key]) is not int or not 0 <= value[key] <= maximum:
            raise ValueError('persistent_ui_count_' + key)
    counts = value['request_counts']
    if not isinstance(counts, list) or len(counts) != 2 or any(type(n) is not int or not 0 <= n <= 1 for n in counts):
        raise ValueError('persistent_ui_requests')
    if mode == 'reopen' and (counts != [0, 0] or value['cover_gets'] or value['progress_gets']):
        raise ValueError('persistent_ui_offline_network')
    if value['known_progress'] > value['progress_snapshots']:
        raise ValueError('persistent_ui_progress')
    if value['cover_retries'] > value['cover_gets']:
        raise ValueError('persistent_ui_requests')
    if value['result'] == 'PASS' and (value['phase'] != 'complete' or not all(value[k] for k in FLAGS)
            or value['forbidden_requests'] or value['screenshots'] or value['failed_line'] or not value['shelf_books'] or not value['profile_files_audited']
            or value['painted_views'] != 3 + int(value['paged_shelf']) or not value['cover_cells']
            or not value['progress_snapshots'] or mode == 'live' and (counts != [1, 1]
                or not value['cover_gets'] or not value['progress_gets'])):
        raise ValueError('persistent_ui_incomplete')
    return value


def decode_stage(raw, mode):
    if not isinstance(raw, bytes) or len(raw) > 2 * 1024 * 1024 or raw.count(FRAME) != 1:
        raise ValueError('persistent_ui_frame')
    return validate_stage(json.loads(raw.split(FRAME)[1]), mode)


def decode_result(raw):
    if not isinstance(raw, bytes) or len(raw) > 65536 or raw.count(FRAME) != 1:
        raise ValueError('persistent_ui_frame')
    value = json.loads(raw.split(FRAME)[1])
    if (not isinstance(value, dict) or set(value) != {'result', 'tmpfs_profile', 'profile_removed', 'stages', 'runner_error'}
            or type(value['tmpfs_profile']) is not bool or type(value['profile_removed']) is not bool
            or value['result'] not in ('PASS', 'UNVERIFIED') or not isinstance(value['stages'], list)
            or len(value['stages']) > 2 or type(value['runner_error']) is not str or value['runner_error'] not in RUNNER_ERRORS):
        raise ValueError('persistent_ui_runner_schema')
    for mode, stage in zip(('live', 'reopen'), value['stages']):
        validate_stage(stage, mode)
    if value['result'] == 'PASS' and (value['runner_error'] != 'none' or not value['tmpfs_profile'] or not value['profile_removed']
            or len(value['stages']) != 2 or any(s['result'] != 'PASS' for s in value['stages'])
            or any(value['stages'][0][k] != value['stages'][1][k]
                   for k in ('shelf_books', 'shelf_groups', 'progress_snapshots', 'known_progress', 'cover_cells'))):
        raise ValueError('persistent_ui_runner_incomplete')
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
    parser.add_argument('--lua-command', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if bool(args.saved_session) != bool(args.lua_command):
        parser.error('pair --saved-session and --lua-command; put --lua-command last')
    report = dict(result='OFFLINE_ONLY', checked_at=datetime.now(timezone.utc).isoformat(),
                  credentials_written_to_persistent_files=False, private_data_on_regular_disk=False,
                  account_data_writes_attempted=0, authentication_posts_attempted=0, screenshots=0)
    credentials = probe = saved = None
    try:
        if args.saved_session:
            store = SessionStore()
            saved = store.load()
            credentials = NativeSessionStore().load(saved['vid'])
            probe = NativeMetadataProbe()
            baseline = probe.inspect(credentials, 1)
            sample = probe.samples[0]
            cookies, rotated = verified_web_snapshot(store, saved)
            report['web_cookie_rotation_saved'] = rotated
            payload = dict(credentials=credentials, cookies=cookies,
                           book_id=sample['book_id'], expected_metadata=sample['expected'],
                           shelf_books=baseline['shelf_book_count'])
            encoded = json.dumps(payload, ensure_ascii=False).encode()
            if len(encoded) > 256 * 1024:
                raise ValueError('persistent_ui_input_limit')
            child = subprocess.run(args.lua_command, input=encoded, capture_output=True, timeout=320)
            domains = re.findall(rb'(?m)^WEREAD_PUBLIC_COVER_DOMAIN=([a-z-]{1,63}\.[a-z]{2,12})$', child.stderr)
            if domains:
                report['blocked_image_domains'] = sorted({d.decode('ascii') for d in domains})
            value = decode_result(child.stdout)
            report.update(ui=value, python_preflight_gets=3, same_owner_verified=True)
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
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report['result'] in ('OFFLINE_ONLY', 'OWNER_FILE_BACKED_UI_READ_VERIFIED') else 1


if __name__ == '__main__':
    raise SystemExit(main())
