#!/usr/bin/env python3
"""Bounded read-only native bookstore prototype; offline by default.

Uses only the owner-approved native Keychain item and known GET contracts
from MiuRead eink_client.lua. Book identities, titles, query results, session
IDs and tokens remain in memory. No account data write or renewal exists.
"""
import argparse
from datetime import datetime,timezone
import json
import math
import subprocess
from urllib.parse import parse_qs,urlencode,urlsplit

from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore,StoreError
from verify_book_metadata import normalize as metadata
from verify_eink_login import BASE,NativeProbe,ProbeError


class DiscoveryError(ValueError):pass


def identity(value):
    if isinstance(value,bool) or not isinstance(value,(str,int)):return None
    value=str(value)
    return value if value.isascii() and value.isdigit() and not value.startswith('0') and len(value)<=20 else None


def text(value,limit):
    return isinstance(value,str) and len(value.encode('utf-8'))<=limit and not any(ord(c)<32 or ord(c)==127 for c in value)


def page(kind,data,cursor=0):
    if not isinstance(data,dict) or any(data.get(k,0) not in (None,0,'0') for k in ('errcode','errCode')) or ('succ' in data and data['succ'] not in (True,1,'1')):
        raise DiscoveryError('native_page_rejected')
    container=data.get('booksimilar') if kind=='similar' and isinstance(data,dict) else data
    if not isinstance(container,dict) or not isinstance(container.get('books'),list) or len(container['books'])>100:
        raise DiscoveryError('native_page_invalid')
    books=[];seen=set();last=cursor
    for row in container['books']:
        if not isinstance(row,dict):raise DiscoveryError('native_row_invalid')
        book=row
        for _ in range(4):
            inner=book.get('bookInfo',book.get('book'))
            if not isinstance(inner,dict):break
            book=inner
        book_id=identity(book.get('bookId'))
        if not book_id:continue
        if not text(book.get('title'),4096):raise DiscoveryError('native_title_invalid')
        idx=row.get('searchIdx',row.get('idx',book.get('searchIdx',book.get('idx'))))
        if type(idx) in (int,float) and math.isfinite(idx) and idx==int(idx) and 0<=idx<=2**31-1:last=max(last,int(idx))
        if book_id not in seen:
            seen.add(book_id)
            books.append(dict(bookId=book_id,title=book['title'],author=book.get('author') if text(book.get('author'),4096) else '',
                              cover=book.get('cover') if text(book.get('cover'),8192) else '',
                              category=book.get('category') if text(book.get('category'),4096) else '',searchIdx=idx))
    more=container.get('hasMore',len(container['books'])>=20) in (True,1,'1')
    if more and last<=cursor:raise DiscoveryError('native_cursor_missing')
    session=container.get('sessionId')
    if session is not None and not text(session,512):raise DiscoveryError('native_session_invalid')
    return dict(books=books,next_cursor=last,has_more=more,session_id=session)


class DiscoveryProbe(NativeProbe):
    def guard(self,stage,url,body):
        parsed=urlsplit(url)
        if body is not None or parsed.scheme!='https' or parsed.netloc!='i.weread.qq.com' or parsed.fragment:
            raise DiscoveryError('native_request_outside_scope')
        query=parse_qs(parsed.query)
        if parsed.path=='/shelf/sync' and stage=='discovery_shelf' and not query:return
        if parsed.path=='/book/info' and stage=='discovery_metadata' and set(query)=={'bookId'} and len(query['bookId'])==1 and identity(query['bookId'][0]):return
        expected={'recommend':('/book/recommend',{'maxIdx','count'}),'search':('/store/search',{'keyword','scope','maxIdx','count'}),
                  'similar':('/book/detailinfo',{'bookId','listtypes','synckey','maxIdx','count'})}
        for kind,(path,keys) in expected.items():
            if stage!=kind or parsed.path!=path:continue
            if not keys<=set(query)<=keys|({'sessionId'} if kind=='similar' else set()) or any(len(v)!=1 for v in query.values()):break
            if not query['maxIdx'][0].isascii() or not query['maxIdx'][0].isdigit() or not 0<=int(query['maxIdx'][0])<=2**31-1 or query['count']!=['20']:break
            if kind=='search' and (query['keyword']!=['三体'] or query['scope']!=['10']):break
            if kind=='similar' and (not identity(query['bookId'][0]) or query['listtypes']!=['2'] or query['synckey']!=['0']):break
            if 'sessionId' in query and not text(query['sessionId'][0],512):break
            return
        raise DiscoveryError('native_request_outside_scope')

    def request(self,stage,url,body=None,credentials=None,timeout=15):
        self.guard(stage,url,body)
        return super().request(stage,url,body,credentials,timeout)

    def inspect(self,credentials):
        self.samples=[]
        shelf=self.request('discovery_shelf',BASE+'/shelf/sync',credentials=credentials)
        if not isinstance(shelf.get('books'),list) or len(shelf['books'])>5000:raise DiscoveryError('native_shelf_invalid')
        target=next((identity(b.get('bookId')) for b in shelf['books'] if isinstance(b,dict) and identity(b.get('bookId'))),None)
        if not target:raise DiscoveryError('native_no_shelf_book')
        details=metadata(self.request('discovery_metadata',BASE+'/book/info?'+urlencode(dict(bookId=target)),credentials=credentials),target)
        results=[]
        for kind,path,extra in (('recommend','/book/recommend',{}),('search','/store/search',dict(keyword='三体',scope=10)),
                                ('similar','/book/detailinfo',dict(bookId=target,listtypes=2,synckey=0))):
            query=dict(maxIdx=0,count=20,**extra)
            source=self.request(kind,BASE+path+'?'+urlencode(query),credentials=credentials)
            first=page(kind,source)
            self.samples.append(dict(kind=kind,cursor=0,source=source,expected=first))
            record=dict(kind=kind,first_count=len(first['books']),has_more=first['has_more'],session_returned=bool(first['session_id']))
            if first['has_more']:
                if kind=='similar':
                    if not first['session_id']:raise DiscoveryError('native_similar_session_missing')
                    extra['sessionId']=first['session_id']
                source=self.request(kind,BASE+path+'?'+urlencode(dict(maxIdx=first['next_cursor'],count=20,**extra)),credentials=credentials)
                second=page(kind,source,first['next_cursor'])
                self.samples.append(dict(kind=kind,cursor=first['next_cursor'],source=source,expected=second))
                overlap={b['bookId'] for b in first['books']} & {b['bookId'] for b in second['books']}
                record.update(second_count=len(second['books']),cursor_advanced=second['next_cursor']>first['next_cursor'],overlap_count=len(overlap),
                              session_preserved=kind!='similar' or second['session_id']==first['session_id'])
                if second['books'] and (not record['cursor_advanced'] or overlap or not record['session_preserved']):raise DiscoveryError('native_page_continuation_unverified')
            results.append(record)
        self.target=target
        return dict(shelf_book_count=len(shelf['books']),book_metadata_field_names=sorted(details),pages=results)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--native-http',action='store_true')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if (args.native_http and not (args.saved_session and args.lua_command)) or (args.lua_command and not args.saved_session):
        parser.error('Lua comparison requires --saved-session; --native-http also requires --lua-command last')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_writes_attempted=0,private_results_saved=False,credentials_written_to_files=False)
    if not args.saved_session:
        assert page('search',dict(books=[dict(bookInfo=dict(bookId='900001',title='Synthetic'),searchIdx=1)],hasMore=0))['next_cursor']==1
        print(json.dumps(report,indent=2));return 0
    credentials=None;probe=DiscoveryProbe()
    try:
        owner=SessionStore().load()['vid']
        credentials=NativeSessionStore().load(owner)
        report.update(probe.inspect(credentials))
        if args.lua_command:
            payload=dict(samples=probe.samples)
            if args.native_http:payload.update(credentials=credentials,book_id=probe.target)
            encoded=json.dumps(payload,ensure_ascii=False).encode()
            if len(encoded)>4*1024*1024:raise DiscoveryError('probe_input_too_large')
            child=subprocess.run(args.lua_command,input=encoded,capture_output=True,timeout=90)
            frame=b'\nWEREAD_DISCOVERY_RESULT='
            if child.returncode or len(child.stdout)>4*1024*1024 or child.stdout.count(frame)!=1:raise DiscoveryError('lua_probe_failed')
            actual=json.loads(child.stdout.split(frame)[1])
            expected=[s['expected'] for s in probe.samples]
            # JSON null is omitted by the Lua codec; compare optional fields canonically.
            for value in expected:
                if value.get('session_id') is None:value.pop('session_id',None)
                for book in value['books']:
                    if book.get('searchIdx') is None:book.pop('searchIdx',None)
            for value in actual.get('model',[]):
                if value.get('books')=={}:value['books']=[]
            if actual.get('model')!=expected:raise DiscoveryError('lua_projection_mismatch')
            report['lua_projection_matches']=True
            if args.native_http:
                pages=actual.get('native_pages')
                if not isinstance(pages,list) or [p.get('kind') for p in pages]!=['recommend','search','similar']:
                    raise DiscoveryError('native_https_invalid')
                report.update(native_https_verified=True,native_pages=pages,native_read_requests=actual.get('requests'))
        report.update(result='NATIVE_DISCOVERY_CONTRACT_VERIFIED',same_owner_verified=True,stages=probe.report['stages'])
    except (StoreError,ProbeError,DiscoveryError) as exc:report.update(result='UNVERIFIED',reason=str(exc),stages=probe.report['stages'])
    except Exception:report.update(result='UNVERIFIED',reason='native_discovery_failed',stages=probe.report['stages'])
    finally:
        if credentials:credentials.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2))
    return 0 if report['result']=='NATIVE_DISCOVERY_CONTRACT_VERIFIED' else 1


if __name__=='__main__':raise SystemExit(main())
