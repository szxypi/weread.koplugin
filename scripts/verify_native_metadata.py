#!/usr/bin/env python3
"""Read-only E-Ink book metadata; offline unless saved-session is explicit.

The owner-approved native Keychain entry is separate from Web cookies. Only
the existing shelf and at most four selected shelf-book metadata GETs are
allowed. Private responses and credentials stay in captured memory pipes.
"""
import argparse
from datetime import datetime,timezone
import json
import subprocess
from urllib.parse import parse_qs,urlencode,urlsplit

from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore,StoreError
from verify_book_metadata import MetadataError,normalize
from verify_eink_login import BASE,NativeProbe,ProbeError
from verify_native_discovery import identity


def normalize_native(source,book_id):
    if isinstance(source,dict):
        source=source.copy()
        if source.get('wordCount') is None:source['wordCount']=source.get('totalWords')
    return normalize(source,book_id)


class NativeMetadataProbe(NativeProbe):
    def __init__(self):
        super().__init__()
        self.allowed_ids=set()
        self.samples=[]

    def guard(self,stage,url,body):
        parsed=urlsplit(url)
        query=parse_qs(parsed.query,keep_blank_values=True)
        if body is not None or parsed.scheme!='https' or parsed.netloc!='i.weread.qq.com' or parsed.fragment:
            raise MetadataError('native_request_outside_scope')
        if stage=='metadata_shelf' and parsed.path=='/shelf/sync' and not query:return
        if (stage=='metadata' and parsed.path=='/book/info' and set(query)=={'bookId'}
                and len(query['bookId'])==1 and query['bookId'][0] in self.allowed_ids):return
        raise MetadataError('native_request_outside_scope')

    def request(self,stage,url,body=None,credentials=None,timeout=15):
        self.guard(stage,url,body)
        return super().request(stage,url,body,credentials,timeout)

    def inspect(self,credentials,sample_count):
        if type(sample_count) is not int or not 1<=sample_count<=4:raise MetadataError('sample_limit_invalid')
        shelf=self.request('metadata_shelf',BASE+'/shelf/sync',credentials=credentials)
        books=shelf.get('books') if isinstance(shelf,dict) else None
        if not isinstance(books,list) or len(books)>5000:raise MetadataError('native_shelf_invalid')
        ids=[]
        for book in books:
            book_id=identity(book.get('bookId')) if isinstance(book,dict) else None
            if book_id and book_id not in ids:ids.append(book_id)
            if len(ids)==sample_count:break
        if not ids:raise MetadataError('native_no_eligible_book')
        self.allowed_ids=set(ids)
        counts={}
        for book_id in ids:
            source=self.request('metadata',BASE+'/book/info?'+urlencode(dict(bookId=book_id)),credentials=credentials)
            metadata=normalize_native(source,book_id)
            self.samples.append(dict(book_id=book_id,source=source,expected=metadata,native=True))
            for key in metadata:counts[key]=counts.get(key,0)+1
        return dict(shelf_book_count=len(books),sampled_book_count=len(ids),display_field_counts=counts)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--sample',type=int,choices=range(1,5),default=2)
    parser.add_argument('--native-http',action='store_true')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if (args.native_http and not (args.saved_session and args.lua_command)) or (args.lua_command and not args.saved_session):
        parser.error('Lua comparison requires --saved-session; --native-http also requires --lua-command last')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_writes_attempted=0,
                private_metadata_saved=False,credentials_written_to_files=False,positions_or_versions_exported=False)
    if not args.saved_session:
        assert normalize(dict(bookId='900001',title='Synthetic',version=700,progress=99),'900001')==dict(bookId='900001',title='Synthetic')
        print(json.dumps(report,indent=2));return 0
    credentials=None;probe=None
    try:
        owner=SessionStore().load()['vid']
        credentials=NativeSessionStore().load(owner)
        probe=NativeMetadataProbe()
        report.update(probe.inspect(credentials,args.sample))
        if args.lua_command:
            payload=dict(samples=probe.samples)
            if args.native_http:payload['native_credentials']=credentials
            encoded=json.dumps(payload,ensure_ascii=False).encode()
            if len(encoded)>2*1024*1024:raise MetadataError('probe_input_too_large')
            child=subprocess.run(args.lua_command,input=encoded,capture_output=True,timeout=90)
            frame=b'\nWEREAD_METADATA_RESULT='
            if child.returncode or len(child.stdout)>2*1024*1024 or child.stdout.count(frame)!=1:raise MetadataError('lua_probe_failed')
            actual=json.loads(child.stdout.split(frame)[1])
            expected=[sample['expected'] for sample in probe.samples]
            if actual.get('model')!=expected:raise MetadataError('lua_projection_mismatch')
            report['lua_projection_matches']=True
            if args.native_http:
                if actual.get('native')!=expected or actual.get('requests')!=len(expected):raise MetadataError('native_readback_mismatch')
                report.update(native_https_projection_matches=True,native_read_requests=actual['requests'])
        report.update(result='NATIVE_METADATA_CONTRACT_VERIFIED',same_owner_verified=True,stages=probe.report['stages'])
    except (StoreError,ProbeError,MetadataError) as exc:report.update(result='UNVERIFIED',reason=str(exc))
    except Exception:report.update(result='UNVERIFIED',reason='native_metadata_verification_failed')
    finally:
        if credentials:credentials.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2))
    return 0 if report['result']=='NATIVE_METADATA_CONTRACT_VERIFIED' else 1


if __name__=='__main__':raise SystemExit(main())
