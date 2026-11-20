#!/usr/bin/env python3
"""Read-only book-display metadata from the existing Web Reader page.

Default is offline. --saved-session verifies the owner, then inspects at most
four existing shelf books. HTML, credentials and book identities stay in
memory. The projection excludes positions, session tokens and file versions.
"""
import argparse
from datetime import datetime, timezone
import json
import math
import re
import subprocess

from fetch_weread_epub import extract_initial_state, reader_url_for
from secure_weread_session import COOKIE_NAMES, SessionStore, StoreError
from verify_web_source_progress import BASE, PreflightError, WebSourceProbe, identifier

TEXT_FIELDS={'author':4096,'translator':4096,'intro':65536,'publisher':4096,'isbn':256,'cover':8192}
NUMBER_FIELDS={'wordCount':1e10,'newRating':1000,'newRatingCount':1e10}


class MetadataError(ValueError):pass


def text(value,limit,multiline=False):
    if not isinstance(value,str):return False
    try:
        return len(value.encode('utf-8'))<=limit and not re.search(r'[\x00-\x08\x0b-\x1f\x7f]' if multiline else r'[\x00-\x1f\x7f]',value)
    except UnicodeError:return False


def normalize(source,book_id):
    if not isinstance(source,dict) or str(source.get('bookId',''))!=book_id or not text(source.get('title'),4096) or not source['title']:
        raise MetadataError('metadata_identity_or_title_invalid')
    if any(source.get(key,0) not in (None,0,'0') for key in ('errcode','errCode')) or ('succ' in source and source['succ'] not in (True,1,'1')):
        raise MetadataError('metadata_rejected')
    result=dict(bookId=book_id,title=source['title'])
    for key,limit in TEXT_FIELDS.items():
        if text(source.get(key),limit,key=='intro'):result[key]=source[key]
    for key,limit in NUMBER_FIELDS.items():
        value=source.get(key)
        if type(value) in (int,float) and math.isfinite(value) and 0<=value<=limit:result[key]=value
    category=source.get('categoryName') or source.get('category')
    if text(category,4096):result['categoryName']=category
    published=source.get('publishTime')
    if text(published,128) or type(published) in (int,float) and math.isfinite(published) and 0<=published<=1e12:
        result['publishTime']=published
    return result


def from_reader(html,book_id):
    try:
        state=extract_initial_state(html)
        reader=state.get('reader') if isinstance(state,dict) else None
        return normalize(reader.get('bookInfo') if isinstance(reader,dict) else None,book_id)
    except MetadataError:raise
    except Exception:raise MetadataError('reader_metadata_invalid') from None


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--sample',type=int,choices=range(1,5),default=2)
    parser.add_argument('--native-http',action='store_true')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if args.native_http and not (args.saved_session and args.lua_command) or args.lua_command and not args.saved_session:
        parser.error('Lua comparison requires --saved-session; --native-http also requires --lua-command last')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_writes_attempted=0,
                private_metadata_saved=False,credentials_written_to_files=False)
    if not args.saved_session:
        result=normalize(dict(bookId='900001',title='Synthetic',version=7,chapterOffset=123,token='synthetic'),'900001')
        assert result==dict(bookId='900001',title='Synthetic')
        print(json.dumps(report,indent=2));return 0
    probe=WebSourceProbe()
    try:
        saved=SessionStore().load()
        probe.vid=identifier(saved['vid'])
        for key,value in saved['cookies'].items():probe.set_cookie(key,value)
        probe.verify_account()
        shelf=probe.request('shelf',BASE+'/web/shelf/sync')
        books=shelf.get('books') if isinstance(shelf,dict) else None
        if not isinstance(books,list) or len(books)>5000:raise MetadataError('shelf_invalid')
        ids=[]
        for source in books:
            try:book_id=identifier(source.get('bookId') if isinstance(source,dict) else None)
            except PreflightError:continue
            if book_id not in ids:ids.append(book_id)
            if len(ids)==args.sample:break
        if not ids:raise MetadataError('no_eligible_books')
        fields={};samples=[];expected=[]
        for book_id in ids:
            probe.book_id=book_id
            html=probe.request('reader',reader_url_for(book_id),as_json=False)
            metadata=from_reader(html,book_id)
            samples.append(dict(book_id=book_id,source=extract_initial_state(html)['reader']['bookInfo']))
            expected.append(metadata)
            for key in metadata:fields[key]=fields.get(key,0)+1
        refreshed={c.name:c.value for c in probe.cookies if c.name in COOKIE_NAMES and c.domain in ('.weread.qq.com','weread.qq.com') and c.path=='/'}
        if refreshed!=saved['cookies']:
            SessionStore().save(probe);report['refreshed_session_saved_to_keychain']=True
        saved['cookies']=refreshed
        if args.lua_command:
            payload=dict(samples=samples)
            if args.native_http:payload['session']=saved
            encoded=json.dumps(payload,ensure_ascii=False).encode()
            if len(encoded)>2*1024*1024:raise MetadataError('probe_input_too_large')
            completed=subprocess.run(args.lua_command,input=encoded,capture_output=True,timeout=90)
            frame=b'\nWEREAD_METADATA_RESULT='
            if completed.returncode or len(completed.stdout)>2*1024*1024 or completed.stdout.count(frame)!=1:
                raise MetadataError('lua_probe_failed')
            actual=json.loads(completed.stdout.split(frame)[1])
            if actual.get('model')!=expected:raise MetadataError('lua_projection_mismatch')
            report['lua_projection_matches']=True
            if args.native_http:
                if actual.get('native')!=expected:raise MetadataError('native_readback_mismatch')
                report.update(native_https_projection_matches=True,native_read_requests=actual.get('requests'))
        saved.clear()
        report.update(result='BOOK_METADATA_CONTRACT_VERIFIED',owner_verified=True,shelf_book_count=len(books),
                      sampled_book_count=len(ids),display_field_counts=fields,positions_or_versions_exported=False,
                      stages=probe.report['stages'])
    except (StoreError,PreflightError,MetadataError) as exc:report.update(result='UNVERIFIED',reason=str(exc))
    except Exception:report.update(result='UNVERIFIED',reason='verification_failed')
    finally:probe.close()
    print(json.dumps(report,indent=2))
    return 0 if report['result']=='BOOK_METADATA_CONTRACT_VERIFIED' else 1


if __name__=='__main__':raise SystemExit(main())
