#!/usr/bin/env python3
"""Check same-book download Reader context. Offline unless --saved-session.

Private HTML, session fields and positions stay in memory. This exercises only
existing Reader GETs and account/shelf reads, never account data writes.
"""
import argparse
from datetime import datetime, timezone
import json
import re
import subprocess
from urllib.parse import urlsplit

from fetch_weread_epub import extract_initial_state, reader_url_for
from secure_weread_session import COOKIE_NAMES, SessionStore, StoreError
from verify_web_source_progress import BASE, PreflightError, WebSourceProbe


class ContextError(ValueError):
    pass


def identifier(value, *, chapter=False):
    if isinstance(value, bool) or not isinstance(value, (int, str)):
        raise ContextError('reader_context/invalid_identity')
    if isinstance(value, int) and not (0 if chapter else 1) <= value <= 9007199254740991:
        raise ContextError('reader_context/invalid_identity')
    value = str(value)
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,127}', value) or (not chapter and value.startswith('MP_WXS_')):
        raise ContextError('reader_context/invalid_identity')
    if value.isdecimal() and (len(value)>20 or (value.startswith('0') and not (chapter and value=='0'))):
        raise ContextError('reader_context/invalid_identity')
    return value


def book_id(book):
    if not isinstance(book, dict):
        raise ContextError('reader_context/invalid_identity')
    values = [identifier(book[key]) for key in ('book_id', 'bookId') if book.get(key) is not None]
    if not values or len(set(values)) != 1:
        raise ContextError('reader_context/invalid_identity')
    return values[0]


def request_url(book, chapter=None):
    key = book_id(book)
    if chapter is not None:
        return reader_url_for(key, identifier(chapter, chapter=True))
    root = reader_url_for(key)
    value = book.get('reader_url')
    if not isinstance(value, str) or len(value.encode('utf-8')) > 4096 or re.search(r'[\x00-\x20\x7f]', value):
        return root
    try:
        parts = urlsplit(value)
    except ValueError:
        return root
    if parts.scheme.lower() != 'https' or parts.netloc.lower() != 'weread.qq.com':
        return root
    path = parts.path
    expected = root[len(BASE):]
    if path == expected or (path.startswith(expected+'k') and re.fullmatch(r'[0-9a-fg]{20,512}', path[len(expected)+1:])):
        return BASE+path
    return root


def session_text(value, *, required=False, counter=False):
    if value is None:
        if required: raise ContextError('reader_context/invalid_session')
        return None
    if counter and type(value) is int and 0<=value<=9007199254740991:
        return value
    if not isinstance(value, str) or len(value.encode('utf-8')) > 4096 or re.search(r'[\x00-\x20\x7f]', value) or required and not value:
        raise ContextError('reader_context/invalid_session')
    return value


def project(book, html):
    key = book_id(book)
    if not isinstance(html, str) or len(html.encode('utf-8')) > 4*1024*1024:
        raise ContextError('reader_context/invalid_response')
    try:
        reader = extract_initial_state(html)['reader']
        info = reader['bookInfo']
        if identifier(info['bookId']) != key:
            raise ContextError('reader_context/book_mismatch')
        chapter = reader.get('currentChapter')
        if chapter is None: chapter = {}
        progress = reader.get('progress')
        if progress is None: progress = {}
        if not isinstance(chapter, dict) or not isinstance(progress, dict):
            raise ContextError('reader_context/invalid_response')
        progress = progress.get('book', progress)
        if not isinstance(progress, dict):
            raise ContextError('reader_context/invalid_response')
        for row in (chapter, progress):
            if row.get('bookId') is not None and identifier(row['bookId']) != key:
                raise ContextError('reader_context/book_mismatch')
        chapter = {key: value for key, value in chapter.items() if value is not None}
        progress = {key: value for key, value in progress.items() if value is not None}
        result = dict(book_id=key, psvts=session_text(reader.get('psvts'), required=True),
                      current_chapter=chapter, progress=progress)
        for field in ('pclts', 'token'):
            value = session_text(reader.get(field),counter=field=='pclts')
            if value is not None: result[field] = value
        for field in ('title', 'author'):
            if isinstance(info.get(field), str): result[field] = info[field]
        return result
    except ContextError:
        raise
    except (KeyError, TypeError, ValueError):
        raise ContextError('reader_context/invalid_response') from None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--native-http', action='store_true')
    parser.add_argument('--lua-command', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if (args.native_http or args.lua_command) and not args.saved_session or args.native_http and not args.lua_command:
        parser.error('comparisons require --saved-session; --native-http requires --lua-command last')
    report = dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),
                  account_writes_attempted=0,credentials_written_to_files=False,private_context_saved=False)
    if not args.saved_session:
        sample=dict(book_id='900001',reader_url='https://example.invalid/stale')
        assert request_url(sample)==reader_url_for('900001')
        print(json.dumps(report,indent=2));return 0
    probe=WebSourceProbe()
    try:
        saved=SessionStore().load()
        probe.vid=saved['vid']
        for key,value in saved['cookies'].items(): probe.set_cookie(key,value)
        probe.verify_account()
        shelf=probe.request('shelf',BASE+'/web/shelf/sync')
        rows=shelf.get('books') if isinstance(shelf,dict) else None
        if not isinstance(rows,list) or len(rows)>5000: raise ContextError('shelf_invalid')
        keys=[]
        for row in rows:
            try: key=identifier(row.get('bookId') if isinstance(row,dict) else None)
            except ContextError: continue
            if key not in keys: keys.append(key)
            if len(keys)==2: break
        if not keys: raise ContextError('no_eligible_books')
        samples,expected=[],[]
        for key in keys:
            probe.book_id=key
            book=dict(book_id=key,reader_url='https://example.invalid/stale')
            url=request_url(book)
            html=probe.request('reader',url,as_json=False)
            state=project(book,html)
            samples.append(dict(book=book,html=html,url=url));expected.append(state)
        probe.verify_account()
        refreshed={c.name:c.value for c in probe.cookies if c.name in COOKIE_NAMES and c.domain in ('.weread.qq.com','weread.qq.com') and c.path=='/'}
        if refreshed!=saved['cookies']:
            SessionStore().save(probe);report['refreshed_session_saved_to_keychain']=True
        saved['cookies']=refreshed
        if args.lua_command:
            payload=dict(samples=samples)
            if args.native_http: payload['session']=saved
            encoded=json.dumps(payload,ensure_ascii=False).encode()
            if len(encoded)>12*1024*1024: raise ContextError('probe_too_large')
            result=subprocess.run(args.lua_command,input=encoded,capture_output=True,timeout=90)
            marker=b'\nWEREAD_CONTEXT_RESULT='
            if result.returncode or len(result.stdout)>24*1024*1024 or result.stdout.count(marker)!=1: raise ContextError('lua_probe_failed')
            actual=json.loads(result.stdout.split(marker)[1])
            if actual.get('model')!=expected: raise ContextError('lua_context_mismatch')
            report['lua_projection_matches']=True
            if args.native_http:
                native=actual.get('native')
                if not isinstance(native,list) or len(native)!=len(samples): raise ContextError('native_context_mismatch')
                # Session values change per request. Compare both languages on
                # each independent native response, not on an earlier session.
                for sample,item in zip(samples,native):
                    if not isinstance(item,dict) or item.get('context')!=project(sample['book'],item.get('html')):
                        raise ContextError('native_context_mismatch')
                report.update(native_https_context_matches=True,native_read_requests=actual.get('requests'))
        report.update(result='READER_CONTEXT_VERIFIED',owner_verified=True,shelf_book_count=len(rows),sample_count=len(samples),
                      same_book_context=True,strict_initial_state=True,stages=probe.report['stages'])
        saved.clear();samples.clear();expected.clear()
    except (StoreError,PreflightError,ContextError) as exc:
        report.update(result='UNVERIFIED',reason=str(exc))
    except Exception:
        report.update(result='UNVERIFIED',reason='verification_failed')
    finally: probe.close()
    print(json.dumps(report,indent=2))
    return 0 if report['result']=='READER_CONTEXT_VERIFIED' else 1


if __name__=='__main__': raise SystemExit(main())
