#!/usr/bin/env python3
"""Bounded, read-only display-progress prototype. Default is offline.

--saved-session verifies the owner before reading a bounded shelf sample.
Credentials, book identifiers and raw/fractional positions stay in memory;
reports expose counts and fixed statuses only. No account write route exists.
"""
import argparse
from datetime import datetime, timezone
import json
import math
import subprocess

from secure_weread_session import COOKIE_NAMES, SessionStore, StoreError
from verify_web_source_progress import BASE, PreflightError, WebSourceProbe, identifier


class DisplayError(ValueError):
    pass


def parse(data, book_id):
    if not isinstance(data, dict):
        raise DisplayError('progress_invalid')
    for name in ('errcode','errCode'):
        if name in data and data[name] not in (None,0,'0'):
            raise DisplayError('progress_rejected')
    if 'succ' in data and data['succ'] not in (1,True,'1'):
        raise DisplayError('progress_rejected')
    book=data.get('book')
    for node in (data,book):
        if isinstance(node,dict) and 'bookId' in node and str(node['bookId'])!=book_id:
            raise DisplayError('progress_book_mismatch')
    if isinstance(book,dict) and 'progress' in book:
        value=book['progress']
        if type(value) not in (int,float) or not math.isfinite(value) or not 0<=value<=100:
            raise DisplayError('progress_invalid')
        return math.floor(value)
    # An untouched book can have a duration record and no saved position.
    # Keep its display unknown; do not infer 0% from duration or chapter zero.
    if 'recordReadingTime' in data:
        return None
    raise DisplayError('progress_missing')


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--sample',type=int,default=8,choices=range(1,13))
    parser.add_argument('--native-http',action='store_true')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if args.native_http and not (args.saved_session and args.lua_command) or args.lua_command and not args.saved_session:
        parser.error('Lua comparison requires --saved-session; --native-http also requires --lua-command last')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_writes_attempted=0,
                raw_positions_saved=False,credentials_written_to_files=False)
    if not args.saved_session:
        assert parse(dict(book=dict(bookId='900001',progress=37.8)),'900001')==37
        assert parse(dict(recordReadingTime=12),'900001') is None
        print(json.dumps(report,indent=2))
        return 0
    probe=WebSourceProbe()
    try:
        saved=SessionStore().load()
        probe.vid=identifier(saved['vid'])
        for key,value in saved['cookies'].items():probe.set_cookie(key,value)
        probe.verify_account()
        shelf=probe.request('shelf',BASE+'/web/shelf/sync')
        books=shelf.get('books') if isinstance(shelf,dict) else None
        if not isinstance(books,list) or len(books)>5000:raise DisplayError('shelf_invalid')
        ids=[]
        for book in books:
            try:book_id=identifier(book.get('bookId') if isinstance(book,dict) else None)
            except PreflightError:continue
            if book_id not in ids:ids.append(book_id)
            if len(ids)==args.sample:break
        values,missing=0,0
        samples=[]
        expected=[]
        for book_id in ids:
            probe.book_id=book_id
            raw=probe.request('selection_progress',BASE+'/web/book/getProgress?bookId='+book_id)
            if len(json.dumps(raw,ensure_ascii=False).encode())>65536:raise DisplayError('progress_response_too_large')
            value=parse(raw,book_id)
            samples.append(dict(book_id=book_id,raw=raw))
            if value is not None:expected.append(dict(book_id=book_id,percent=value))
            values+=value is not None
            missing+=value is None
        if not ids:raise DisplayError('no_eligible_books')
        refreshed={cookie.name:cookie.value for cookie in probe.cookies if cookie.name in COOKIE_NAMES
                   and cookie.domain in ('.weread.qq.com','weread.qq.com') and cookie.path=='/'}
        report['session_cookie_refreshed']=refreshed!=saved['cookies']
        saved['cookies']=refreshed
        if report['session_cookie_refreshed']:
            # Preserve the newly verified session before optional comparisons.
            SessionStore().save(probe)
            report['refreshed_session_saved_to_keychain']=True
        if args.lua_command:
            payload=dict(samples=samples)
            if args.native_http:payload['session']=saved
            encoded=json.dumps(payload,ensure_ascii=False).encode()
            if len(encoded)>1024*1024:raise DisplayError('probe_input_too_large')
            result=subprocess.run(args.lua_command,input=encoded,capture_output=True,timeout=90)
            frame=b'\nWEREAD_DISPLAY_RESULT='
            if len(result.stdout)>1024*1024 or result.stdout.count(frame)!=1:
                raise DisplayError('lua_probe_failed')
            actual=json.loads(result.stdout.split(frame)[1])
            if result.returncode:
                stage=actual.get('stage')
                codes=actual.get('statuses')
                if isinstance(codes,list) and len(codes)<=args.sample and all(type(c) is int and 0<=c<=599 for c in codes):
                    report['native_http_statuses']=codes
                notes=actual.get('diagnostics')
                fields={'has_book','valid_display','unavailable','read_failed','decode_failed','limit_or_http_failed'}
                if isinstance(notes,list) and len(notes)<=args.sample and all(isinstance(n,dict) and set(n)<=fields
                        and all(type(v) is bool for v in n.values()) for n in notes):
                    report['native_diagnostics']=notes
                raise DisplayError('lua_probe_failed/'+stage if stage in {'model','client','fetch'} else 'lua_probe_failed')
            if actual.get('model')!=expected:raise DisplayError('lua_projection_mismatch')
            report['lua_display_projection_matches']=True
            if args.native_http:
                if actual.get('native')!=expected:raise DisplayError('native_readback_mismatch')
                report.update(native_https_projection_matches=True,native_read_requests=actual.get('requests'))
        saved.clear()
        report.update(result='DISPLAY_PROGRESS_CONTRACT_VERIFIED',owner_verified=True,shelf_book_count=len(books),
                      sampled_book_count=len(ids),display_progress_count=values,unavailable_position_count=missing,
                      stages=probe.report['stages'])
    except (StoreError,PreflightError,DisplayError) as exc:
        report.update(result='UNVERIFIED',reason=str(exc))
    except Exception:
        report.update(result='UNVERIFIED',reason='verification_failed')
    finally:
        probe.close()
    print(json.dumps(report,indent=2))
    return 0 if report['result']=='DISPLAY_PROGRESS_CONTRACT_VERIFIED' else 1


if __name__=='__main__':raise SystemExit(main())
