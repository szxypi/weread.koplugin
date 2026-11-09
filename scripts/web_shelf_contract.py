"""Bounded display projection for the authenticated Web shelf read prototype.

Never serialize/log the returned private metadata in verification reports.
Web shelf `version` is observational and must not become EPUB bookVersion.
"""
import math
import re
from shelf_flags_contract import flag


class ShelfError(ValueError):
    pass


def text(value, limit):
    try:
        return isinstance(value, str) and len(value.encode('utf-8')) <= limit and not re.search(r'[\x00-\x1f\x7f]', value)
    except UnicodeError:
        return False


def identity(value):
    if type(value) in (int, float):
        if not math.isfinite(value) or value < 1 or value != int(value) or value > 9007199254740990:
            return None
        value = str(int(value))
    return value if text(value, 256) and value else None


def number(value):
    if isinstance(value, bool):
        return None
    try:
        value = float(value)
        return value if math.isfinite(value) and value >= 0 else None
    except (ValueError, TypeError, OverflowError):
        return None


def normalize(data):
    if (not isinstance(data, dict) or not isinstance(data.get('books'), list) or len(data['books']) > 5000
            or not isinstance(data.get('archive', []), list) or len(data.get('archive', [])) > 1000):
        raise ShelfError('web_shelf_invalid')
    books, archives, seen = [], [], set()
    for source in data['books']:
        book_id = identity(source.get('bookId')) if isinstance(source, dict) else None
        if not book_id or book_id in seen or not text(source.get('title'), 4096):
            raise ShelfError('web_shelf_invalid')
        seen.add(book_id)
        book = dict(bookId=book_id, title=source['title'], author=source.get('author') if text(source.get('author'), 4096) else '',
                    readUpdateTime=number(source.get('readUpdateTime')) or 0)
        observed = number(source.get('version'))
        if observed is not None:
            book['_web_shelf_version'] = observed
        for key in ('cover', 'coverUrl', 'format'):
            if text(source.get(key), 8192):
                book[key] = source[key]
        for key in ('finishReading','secret','isTop'):
            state=flag(source,key)
            if 'value' in state: book[key]=state['value'] if key=='isTop' else int(state['value'])
        for key in ('finished',):
            if type(source.get(key)) in (int, float) and source[key] in (0, 1):
                book[key] = source[key]
        books.append(book)
    for source in data.get('archive', []):
        if not isinstance(source, dict) or not isinstance(source.get('bookIds'), list) or len(source['bookIds']) > 5000:
            raise ShelfError('web_shelf_invalid')
        archive = dict(name=source.get('name') if text(source.get('name'), 4096) else '', bookIds=[])
        archive_id = identity(source.get('archiveId'))
        if archive_id:
            archive['archiveId'] = archive_id
        for value in source['bookIds']:
            book_id = identity(value)
            if not book_id:
                raise ShelfError('web_shelf_invalid')
            archive['bookIds'].append(book_id)
        archives.append(archive)
    return dict(books=books, archive=archives)


def main(argv=None):
    """Offline by default. Reports contain counts/booleans only, never metadata."""
    import argparse
    from datetime import datetime, timezone
    import json
    import subprocess
    from secure_weread_session import SessionStore, StoreError
    from verify_web_source_progress import BASE, PreflightError, WebSourceProbe
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session', action='store_true')
    parser.add_argument('--native-http', action='store_true', help='also verify the real Lua login completion and Web shelf over HTTPS')
    parser.add_argument('--lua-command', nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if (args.native_http and not (args.saved_session and args.lua_command)) or (args.lua_command and not args.saved_session):
        parser.error('native HTTP requires --saved-session and --lua-command (last)')
    report = dict(result='OFFLINE_ONLY', checked_at=datetime.now(timezone.utc).isoformat(), account_writes_attempted=0,
                  credentials_written_to_files=False)
    if not args.saved_session:
        assert normalize(dict(books=[dict(bookId='900001',title='Synthetic book',version=7)]))['books'][0]['_web_shelf_version']==7
        print(json.dumps(report,indent=2))
        return 0
    probe = WebSourceProbe()
    try:
        saved=SessionStore().load()
        probe.vid=saved['vid']
        for key,value in saved['cookies'].items():
            probe.set_cookie(key,value)
        probe.verify_account()
        shelf=probe.request('shelf',BASE+'/web/shelf/sync')
        expected=normalize(shelf)
        report.update(owner_verified=True,book_count=len(expected['books']),archive_count=len(expected['archive']),
                      observed_version_count=sum('_web_shelf_version' in b for b in expected['books']),book_version_exported=False)
        if args.lua_command:
            payload=dict(shelf=shelf)
            if args.native_http:
                payload['session']=saved
            encoded=json.dumps(payload,ensure_ascii=False).encode()
            if len(encoded)>6*1024*1024:
                raise ShelfError('probe_input_too_large')
            completed=subprocess.run(args.lua_command,input=encoded,capture_output=True,timeout=90)
            # Bounded private output is never echoed, even on a failed child.
            if len(completed.stdout)>12*1024*1024:
                raise ShelfError('lua_probe_failed')
            frame=b'\nWEREAD_PROBE_RESULT='
            if completed.stdout.count(frame)!=1:
                raise ShelfError('lua_probe_invalid')
            actual=json.loads(completed.stdout.split(frame)[1])
            if completed.returncode:
                stage=actual.get('stage')
                raise ShelfError('lua_probe_failed/'+stage if stage in {'normalize','client','login_module','login_completion','shelf'} else 'lua_probe_failed')
            if actual.get('shelf')!=expected:
                raise ShelfError('lua_projection_mismatch')
            report['lua_projection_matches']=True
            if args.native_http:
                if actual.get('native_http_verified') is not True or actual.get('native_shelf')!=expected:
                    raise ShelfError('native_readback_mismatch')
                report.update(native_https_login_verified=True,native_https_shelf_matches=True,
                              official_key_available=actual.get('key_available'),native_read_requests=actual.get('requests'))
        report.update(result='WEB_SHELF_CONTRACT_VERIFIED',stages=probe.report['stages'])
    except (StoreError,PreflightError,ShelfError) as exc:
        report.update(result='UNVERIFIED',reason=str(exc))
    except Exception:
        report.update(result='UNVERIFIED',reason='verification_failed')
    finally:
        probe.close()
    print(json.dumps(report,indent=2))
    return 0 if report['result']=='WEB_SHELF_CONTRACT_VERIFIED' else 1


if __name__=='__main__':
    raise SystemExit(main())
