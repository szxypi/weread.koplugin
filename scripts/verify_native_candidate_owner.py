#!/usr/bin/env python3
"""Read-only single-chapter downloader probe; private data stays in memory/tmpfs."""
import argparse
import json
import resource
import subprocess

from native_chapter_remote_reference import search_token
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_native_chapter_package import ChapterProbe
from verify_translation_preflight import TranslationWebProbe


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true', required=True)
    parser.add_argument('--book-offset', type=int, default=0, choices=range(0, 51))
    parser.add_argument('--lua-command', nargs=argparse.REMAINDER, required=True)
    args = parser.parse_args()
    report = dict(result='UNVERIFIED', account_data_writes=0, authorization_requests=0,
                  credentials_written_to_files=False, chapter_content_only_on_tmpfs=True)
    try:
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        saved = SessionStore().load()
        credentials = NativeSessionStore().load(saved['vid'])
        sample, chapter, native = ChapterProbe().inspect(credentials, args.book_offset)
        web = TranslationWebProbe()
        web.vid = saved['vid']
        for name, value in saved['cookies'].items():
            web.set_cookie(name, value)
        web.verify_account()
        inspected = web.inspect_content(sample, chapter_uid=chapter['uid'])
        if not inspected.get('content_decoded'):
            raise ValueError('web_unavailable')
        original = web.content_sample['source']
        if not native['html'] or native['source'] != original.encode() or len(original.encode()) > 2*1024*1024:
            raise ValueError('source_not_identical')
        payload = dict(owner=True, credentials=credentials, book_id=sample['book_id'], uid=str(chapter['uid']),
                       book_version=sample['expected']['version'], web=original,
                       search_token=search_token(native['source']))
        child = subprocess.run(args.lua_command, input=json.dumps(payload).encode(), stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, timeout=120, check=False)
        marker = b'WEREAD_CANDIDATE_RESULT='
        if child.returncode or child.stdout.count(marker) != 1 or len(child.stdout) > 65536:
            raise ValueError('native_downloader_failed')
        result = json.loads(child.stdout.split(marker, 1)[1].splitlines()[0])
        if (set(result) != {'ok', 'fallback', 'assets', 'stopped'} or result['ok'] is not True
                or result['fallback'] != 0 or result['stopped'] is not False
                or type(result['assets']) is not int or result['assets'] < 1):
            raise ValueError('native_downloader_unverified')
        report.update(result='PASS', independent_originals_identical=True, native_downloader_completed=True,
                      source_metadata_preserved=True, image_decoded_offline=True, staged_assets=result['assets'])
    except Exception as exc:
        # Never emit request bodies, identifiers, text, paths or exception details.
        allowed = {'web_unavailable', 'source_not_identical', 'native_downloader_failed', 'native_downloader_unverified'}
        report['reason'] = str(exc) if str(exc) in allowed else 'preflight_or_network_failed'
    print(json.dumps(report, ensure_ascii=False))
    return int(report['result'] != 'PASS')


if __name__ == '__main__':
    raise SystemExit(main())
