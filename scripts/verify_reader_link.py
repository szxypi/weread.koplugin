#!/usr/bin/env python3
"""Validate standard Reader-link import using read-only, memory-only metadata.

Offline by default. Saved-session mode rechecks the owner and samples two
existing shelf links. Reports exclude URLs, IDs, HTML, metadata and credentials.
"""
import argparse
from datetime import datetime, timezone
import json
import re
import subprocess
from urllib.parse import urlsplit

from fetch_weread_epub import extract_initial_state, reader_url_for, weread_e
from secure_weread_session import COOKIE_NAMES, SessionStore, StoreError
from verify_book_metadata import MetadataError, normalize
from verify_web_source_progress import BASE, PreflightError, WebSourceProbe, identifier


class LinkError(ValueError):
    pass


def canonical(value):
    if not isinstance(value, str) or len(value.encode('utf-8')) > 4096:
        raise LinkError('link_invalid')
    value = value.strip()
    if re.search(r'[\x00-\x20\x7f]', value):
        raise LinkError('link_invalid')
    u = urlsplit(value)
    if u.scheme.lower() != 'https' or u.netloc.lower() != 'weread.qq.com':
        raise LinkError('link_invalid')
    match = re.fullmatch(r'/web/reader/([0-9a-fg]{20,128})(?:k[0-9a-fg]{20,128})?', u.path)
    if not match:
        raise LinkError('link_invalid')
    return BASE + '/web/reader/' + match[1]


def project(url, html):
    url = canonical(url)
    if not isinstance(html, str) or len(html.encode('utf-8')) > 4 * 1024 * 1024:
        raise LinkError('reader_invalid')
    try:
        state = extract_initial_state(html)
        source = state['reader']['bookInfo']
        book_id = identifier(source['bookId'])
        metadata = normalize(source, book_id)
    except (MetadataError, PreflightError, KeyError, TypeError, ValueError):
        raise LinkError('reader_invalid') from None
    if url != reader_url_for(book_id):
        raise LinkError('reader_mismatch')
    return dict(metadata=metadata, reader_url=url)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--native-http', action='store_true')
    parser.add_argument('--lua-command', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if (args.native_http or args.lua_command) and not args.saved_session or args.native_http and not args.lua_command:
        parser.error('comparisons require --saved-session; --native-http requires --lua-command last')
    report = dict(result='OFFLINE_ONLY', checked_at=datetime.now(timezone.utc).isoformat(),
                  account_writes_attempted=0, credentials_written_to_files=False, private_metadata_saved=False)
    if not args.saved_session:
        url = reader_url_for('900001')
        assert canonical(url+'k'+weread_e('2')+'?wvid=discarded#discarded') == url
        html = 'window.__INITIAL_STATE__='+json.dumps(dict(reader=dict(bookInfo=dict(bookId='900001',title='Synthetic',token='discarded'))))+';(function(){})();'
        assert project(url, html)['metadata'] == dict(bookId='900001', title='Synthetic')
        print(json.dumps(report, indent=2));return 0
    probe = WebSourceProbe()
    try:
        saved = SessionStore().load()
        probe.vid = identifier(saved['vid'])
        for key, value in saved['cookies'].items(): probe.set_cookie(key, value)
        probe.verify_account()
        shelf = probe.request('shelf', BASE+'/web/shelf/sync')
        rows = shelf.get('books') if isinstance(shelf, dict) else None
        if not isinstance(rows, list) or len(rows) > 5000: raise LinkError('shelf_invalid')
        ids = []
        for row in rows:
            try: book_id = identifier(row.get('bookId') if isinstance(row, dict) else None)
            except PreflightError: continue
            if book_id not in ids: ids.append(book_id)
            if len(ids) == 2: break
        if not ids: raise LinkError('no_eligible_books')
        samples, expected = [], []
        for book_id in ids:
            probe.book_id = book_id
            url = reader_url_for(book_id)
            html = probe.request('reader', url, as_json=False)
            expected.append(project(url, html))
            samples.append(dict(url=url+'?wfrom=discarded#discarded', html=html))
        probe.verify_account()
        refreshed={c.name:c.value for c in probe.cookies if c.name in COOKIE_NAMES and c.domain in ('.weread.qq.com','weread.qq.com') and c.path=='/'}
        if refreshed != saved['cookies']:
            SessionStore().save(probe);report['refreshed_session_saved_to_keychain']=True
        saved['cookies'] = refreshed
        if args.lua_command:
            payload=dict(samples=samples)
            if args.native_http: payload['session']=saved
            encoded=json.dumps(payload,ensure_ascii=False).encode()
            if len(encoded)>12*1024*1024: raise LinkError('probe_too_large')
            result=subprocess.run(args.lua_command,input=encoded,capture_output=True,timeout=90)
            frame=b'\nWEREAD_LINK_RESULT='
            if result.returncode or len(result.stdout)>1024*1024 or result.stdout.count(frame)!=1: raise LinkError('lua_probe_failed')
            actual=json.loads(result.stdout.split(frame)[1])
            if actual.get('model') != expected: raise LinkError('lua_projection_mismatch')
            report['lua_projection_matches']=True
            if args.native_http:
                if actual.get('native') != expected: raise LinkError('native_readback_mismatch')
                report.update(native_https_projection_matches=True,native_read_requests=actual.get('requests'))
        saved.clear();samples.clear();expected.clear()
        report.update(result='READER_LINK_CONTRACT_VERIFIED',owner_verified=True,shelf_book_count=len(rows),
                      sampled_link_count=len(ids),same_link_identity=True,positions_or_tokens_exported=False,stages=probe.report['stages'])
    except (StoreError,PreflightError,MetadataError,LinkError) as exc:
        report.update(result='UNVERIFIED',reason=str(exc))
    except Exception:
        report.update(result='UNVERIFIED',reason='verification_failed')
    finally: probe.close()
    print(json.dumps(report,indent=2))
    return 0 if report['result']=='READER_LINK_CONTRACT_VERIFIED' else 1


if __name__=='__main__': raise SystemExit(main())
