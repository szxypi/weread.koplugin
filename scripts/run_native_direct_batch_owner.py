#!/usr/bin/env python3
"""Run a guarded read-only batch in disposable KOReader tmpfs profiles."""
import json
import os
from pathlib import Path
import re
import resource
import subprocess
import sys
import tempfile
import zipfile

from run_native_direct_position_owner import frame, synthetic_endpoint_allowed
from run_persistent_ui_probe import extract_candidate, run_child

REPO = Path(__file__).resolve().parent.parent
MARKER = b'\nWEREAD_BATCH_OWNER_RUN='


def validate(payload):
    if not isinstance(payload, dict) or not synthetic_endpoint_allowed(payload, payload.get('mock_endpoint')):
        raise ValueError('endpoint')
    book = payload.get('book_id')
    version, total, sources = payload.get('version'), payload.get('total'), payload.get('sources')
    if (not isinstance(book, str) or not re.fullmatch(r'[1-9][0-9]{0,19}', book)
            or type(version) is not int or not 0 <= version <= 2147483647
            or type(total) is not int or not 1 <= total <= 200
            or not isinstance(sources, dict) or not 1 <= len(sources) <= min(8, total)):
        raise ValueError('scope')
    for uid, item in sources.items():
        if (not isinstance(uid, str) or not re.fullmatch(r'[1-9][0-9]{0,15}', uid)
                or not isinstance(item, dict) or set(item) not in ({'sha256'}, {'sha256', 'token'})
                or not isinstance(item['sha256'], str) or not re.fullmatch(r'[a-f0-9]{64}', item['sha256'])):
            raise ValueError('source')
        if 'token' in item and (not isinstance(item['token'], str) or not 6 <= len(item['token'].encode()) <= 128
                                or any(ord(char) < 32 for char in item['token'])):
            raise ValueError('token')
    credentials = payload.get('credentials')
    if (not isinstance(credentials, dict) or set(credentials) != {'vid', 'accessToken', 'refreshToken', 'deviceId'}
            or not isinstance(credentials['vid'], str) or not re.fullmatch(r'[1-9][0-9]{0,19}', credentials['vid'])
            or any(not isinstance(credentials[key], str) or not 8 <= len(credentials[key]) <= 4096
                   for key in ('accessToken', 'refreshToken', 'deviceId'))):
        raise ValueError('credentials')
    return payload


def main():
    if (sys.platform != 'linux' or not Path('/validation/runtime/lib/koreader/luajit').is_file()
            or not any(row.split()[1:3] == ['/dev/shm', 'tmpfs'] for row in Path('/proc/mounts').read_text().splitlines())):
        raise SystemExit('Linux, KOReader and tmpfs required')
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    report = dict(result='UNVERIFIED', profile_removed=False)
    root = None
    phase = 'input'
    try:
        raw = sys.stdin.buffer.read(65537)
        if len(raw) > 65536: raise ValueError('input_limit')
        payload = validate(json.loads(raw))
        runtime = Path('/validation/runtime/lib/koreader')
        with tempfile.TemporaryDirectory(prefix='weread-native-batch-owner-', dir='/dev/shm') as temporary:
            root = Path(temporary)
            candidate = root/'candidate.zip'
            subprocess.run(['bash', str(REPO/'scripts/package_release.sh'), str(candidate)], cwd=REPO,
                           env=dict(os.environ, TMPDIR='/dev/shm'), check=True, capture_output=True, timeout=120)
            results = []
            for width, height, dpi in ((600, 800, 167), (1264, 1680, 300)):
                profile, xdg = root/f'profile-{width}', root/f'xdg-{width}'
                (profile/'plugins').mkdir(parents=True);xdg.mkdir(mode=0o700)
                extract_candidate(candidate, profile/'plugins')
                plugin = profile/'plugins/weread.koplugin'
                env = dict(os.environ, KO_HOME=str(profile), XDG_RUNTIME_DIR=str(xdg), LD_LIBRARY_PATH=str(runtime/'libs'),
                           SDL_VIDEODRIVER='dummy', EMULATE_READER='1', EMULATE_BW_SCREEN='1', EMULATE_BB_TYPE='BB8',
                           EMULATE_READER_W=str(width), EMULATE_READER_H=str(height), EMULATE_READER_DPI=str(dpi),
                           WEREAD_DIRECT_OWNER_TMPFS='1')
                size_result = {}
                for mode in ('online', 'repeat', 'offline'):
                    phase = mode
                    private = dict(payload, mode=mode)
                    if mode == 'offline':
                        private.pop('credentials');private.pop('web_cookies', None)
                        private['vid'] = payload['credentials']['vid']
                    code, out, repaint = run_child([str(runtime/'luajit'), str(REPO/'spec/koreader/native_direct_owner_error_guard.lua'),
                        str(plugin), str(REPO/'spec/koreader/native_direct_batch_owner_probe.lua'), str(REPO)],
                        env, json.dumps(private, ensure_ascii=False).encode(), runtime, timeout=360)
                    if code:
                        match = re.search(rb'WEREAD_DIRECT_OWNER_ERROR=(\d+)', out)
                        if match: report['probe_line'] = int(match.group(1))
                    result = frame(out, b'WEREAD_BATCH_OWNER=')
                    if code or repaint or result.get('ok') is not True or result.get('mode') != mode:
                        if result.get('reason') in {'auth_expired', 'rate_limited', 'session_changed', 'catalog_changed',
                                                    'unavailable', 'not_entitled', 'storage', 'invalid_source', 'invalid'}:
                            report['reason'] = result['reason']
                        raise ValueError('probe')
                    if result.get('chapters') != len(payload['sources']): raise ValueError('count')
                    if mode == 'offline':
                        if result.get('network_blocked') is not True or result.get('tokens') != sum('token' in row for row in payload['sources'].values()):
                            raise ValueError('offline')
                    else:
                        if (result.get('source_matches') is not True or result.get('unavailable') != payload['total']-len(payload['sources'])
                                or type(result.get('missing')) is not int or not 0 <= result['missing'] <= len(payload['sources'])
                                or type(result.get('requests')) is not int or not 1 <= result['requests'] <= 200):
                            raise ValueError('online')
                        if mode == 'online': size_result = dict(requests=result['requests'], missing=result['missing'])
                        elif result['requests']-size_result['requests'] != 2 or result['missing'] != size_result['missing']:
                            raise ValueError('repeat')
                phase = 'audit'
                secrets = [payload['credentials'][key].encode() for key in ('accessToken', 'refreshToken', 'deviceId')]
                for item in profile.rglob('*'):
                    if item.is_symlink(): raise ValueError('symlink')
                    if item.is_file() and plugin not in item.parents:
                        if item.stat().st_size > 128*1024*1024: raise ValueError('file_limit')
                        content = item.read_bytes()
                        if any(secret in content for secret in secrets): raise ValueError('credential_file')
                with zipfile.ZipFile(candidate) as archive:
                    for item in archive.infolist():
                        if not item.is_dir() and archive.read(item) != (profile/'plugins'/item.filename).read_bytes():
                            raise ValueError('installed_bytes')
                results.append(size_result)
            report.update(result='PASS', screen_sizes=2, chapters=len(payload['sources']),
                          unavailable=payload['total']-len(payload['sources']), source_matches=True,
                          repeat_skipped=True, offline_render=True, network_blocked=True,
                          credential_file_audit=True, installed_bytes_match=True, samples=results)
    except (Exception, KeyboardInterrupt):
        report['phase'] = phase
    finally:
        report['profile_removed'] = root is not None and not root.exists()
    sys.stdout.buffer.write(MARKER + json.dumps(report).encode() + b'\n')
    return int(report['result'] != 'PASS' or not report['profile_removed'])


if __name__ == '__main__':
    raise SystemExit(main())
