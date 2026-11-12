#!/usr/bin/env python3
"""Read one shelf cover anonymously; default offline, private URLs stay in RAM.

An optional Lua command receives only the selected URL, size and digest through
a captured pipe, never the owner's credentials, identifier, book ID or title.
The native probe must use a fresh /dev/shm profile and disable screenshots.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import subprocess
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import Request, build_opener

from fetch_weread_epub import USER_AGENT
from secure_weread_session import SessionStore
from verify_mp_images import media
from verify_mp_link import NoRedirect
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE, WebSourceProbe, identifier

MAX_BYTES = 3 * 1024 * 1024
FRAME = b'\nWEREAD_COVER_RESULT='


def cover_url(value):
    if not isinstance(value, str) or not 1 <= len(value) <= 8192:
        return None
    if any(ord(c) < 33 or ord(c) == 127 for c in value):
        return None
    if value.startswith('http://wx.qlogo.cn/'):
        value = 'https://' + value[len('http://'):]
    try:
        parsed = urlsplit(value)
    except ValueError:
        return None
    if (parsed.scheme != 'https' or not parsed.hostname or parsed.username
            or parsed.password or parsed.fragment or parsed.netloc != parsed.hostname):
        return None
    return value


def download(url, opener=None):
    if cover_url(url) != url:
        raise ValueError('cover_url_invalid')
    request = Request(url, headers={'User-Agent': USER_AGENT, 'Accept': 'image/*',
                                   'Referer': BASE + '/'}, method='GET')
    try:
        with (opener or build_opener(NoRedirect())).open(request, timeout=15) as response:
            raw = response.read(MAX_BYTES + 1)
            code = response.status
    except HTTPError as exc:
        exc.close()
        raise ValueError('cover_http_failed') from None
    kind = media(raw)
    if code != 200 or not 16 <= len(raw) <= MAX_BYTES or not kind:
        raise ValueError('cover_response_invalid')
    return dict(url=url, bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest()), kind


def decode_result(raw):
    if not isinstance(raw, bytes) or len(raw) > 65536 or raw.count(FRAME) != 1:
        raise ValueError('cover_result_frame')
    value = json.loads(raw.split(FRAME)[1])
    flags = {'anonymous_only', 'digest_matches', 'thumbnail_bounded', 'source_removed',
             'worker_reaped', 'offline_reused', 'painted_cover', 'memory_profile'}
    counts = {'image_gets': 1, 'screenshots': 0, 'forbidden_requests': 1}
    if (not isinstance(value, dict) or set(value) != flags | set(counts) | {'result', 'phase'}
            or type(value['phase']) is not str or type(value['result']) is not str
            or value['phase'] not in {'init', 'input', 'setup', 'transport', 'plugin', 'loading', 'readback', 'complete'}
            or value['result'] not in ('PASS', 'UNVERIFIED') or any(type(value[key]) is not bool for key in flags)
            or any(type(value[key]) is not int or not 0 <= value[key] <= number for key, number in counts.items())):
        raise ValueError('cover_result_invalid')
    if value['result'] == 'PASS' and (value['phase'] != 'complete' or not all(value[key] for key in flags)
                                      or value['image_gets'] != 1 or value['forbidden_requests']):
        raise ValueError('cover_result_incomplete')
    return value


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--lua-command', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.lua_command and not args.saved_session:
        parser.error('Lua comparison requires --saved-session; --lua-command must be last')
    report = dict(result='OFFLINE_ONLY', checked_at=datetime.now(timezone.utc).isoformat(),
                  credentials_sent_to_lua=False, private_urls_saved=False, screenshots=0,
                  account_data_writes_attempted=0, authentication_posts_attempted=0)
    if not args.saved_session:
        print(json.dumps(report, indent=2))
        return 0
    probe, saved = WebSourceProbe(), {}
    try:
        store = SessionStore()
        saved = store.load()
        probe.vid = identifier(saved['vid'])
        for name, value in saved['cookies'].items():
            probe.set_cookie(name, value)
        probe.verify_account()
        shelf = probe.request('shelf', BASE + '/web/shelf/sync')
        books = shelf.get('books') if isinstance(shelf, dict) else None
        if not isinstance(books, list) or not 1 <= len(books) <= 5000:
            raise ValueError('cover_shelf_invalid')
        url = next((url for book in books if isinstance(book, dict)
                    for url in [cover_url(book.get('cover'))] if url), None)
        if not url:
            raise ValueError('cover_missing')
        # Preserve a verified rotation before an optional image/native failure.
        report['web_cookie_rotation_saved'] = save_refreshed_web_session(store, saved, probe)
        sample, kind = download(url)
        report.update(owner_verified=True, shelf_books=len(books), python_image_gets=1,
                      image_media=kind, cookie_sent_to_image=False,
                      authorization_sent_to_image=False, redirects_followed=0)
        if args.lua_command:
            child = subprocess.run(args.lua_command, input=json.dumps(sample).encode(),
                                   capture_output=True, timeout=90)
            report['native'] = decode_result(child.stdout)
            if (child.returncode or report['native']['result'] != 'PASS'
                    or b'[WeRead] forceRePaint failed:' in child.stdout + child.stderr):
                raise ValueError('cover_native_failed')
        report['result'] = 'SHELF_COVER_READ_VERIFIED'
    except Exception:
        report.update(result='UNVERIFIED', reason='shelf_cover_verification_failed')
    finally:
        report['stages'] = probe.report['stages']
        saved.clear()
        probe.close()
    print(json.dumps(report, indent=2))
    return 0 if report['result'] == 'SHELF_COVER_READ_VERIFIED' else 1


if __name__ == '__main__':
    raise SystemExit(main())
