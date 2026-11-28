#!/usr/bin/env python3
"""CB_ display metadata and optional one-book catalog; offline by default.

Verify same-owner native/Web shelf identity sets, then read at most eight
CB_ book-info objects and Web Reader pages once per address/channel. Embedded
state is parsed without running JavaScript. --catalog additionally permits
one existing chapterInfos read POST for the first selected book, never a
progress/time/shelf/annotation write or authorization renewal.
Private objects and credentials stay in memory/captured pipes; reports use
fixed statuses, counts and booleans only. A failed channel stops its reads.
"""
import argparse
from datetime import datetime,timezone
import json
import subprocess
from urllib.parse import parse_qs,urlencode,urlsplit

from fetch_weread_epub import extract_initial_state,normalize_chapter_infos,reader_url_for
from secure_native_session import NativeSessionStore
from secure_weread_session import COOKIE_NAMES,SessionStore
from verify_book_metadata import from_reader
from verify_cb_progress import cb_id,cb_ids
from verify_eink_login import BASE as NATIVE_BASE
from verify_native_metadata import NativeMetadataProbe,normalize_native
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE,WebSourceProbe,identifier


class CbMetadataError(ValueError):pass


class CbNativeMetadataProbe(NativeMetadataProbe):
    def __init__(self):super().__init__();self.seen=set()

    def guard(self,stage,url,body):
        super().guard(stage,url,body)
        if stage=='metadata':
            query=parse_qs(urlsplit(url).query)
            if not cb_id(query['bookId'][0]):raise CbMetadataError('cb_metadata_scope')
        if url in self.seen:raise CbMetadataError('cb_metadata_repeated')
        self.seen.add(url)


class CbMetadataWebProbe(WebSourceProbe):
    def __init__(self):super().__init__();self.allowed=set();self.seen=set();self.catalog_book=None

    def guard(self,stage,url,body):
        if stage not in ('account','shelf','reader','catalog_before'):raise CbMetadataError('cb_metadata_scope')
        if stage in ('reader','catalog_before') and (not cb_id(self.book_id) or self.book_id not in self.allowed):
            raise CbMetadataError('cb_metadata_scope')
        if body is not None and (stage!='catalog_before' or self.book_id!=self.catalog_book):
            raise CbMetadataError('cb_metadata_scope')
        super().guard(stage,url,body)
        if url in self.seen:raise CbMetadataError('cb_metadata_repeated')
        self.seen.add(url)

    def request(self,*args,**kwargs):
        def check_owner():
            owners={cookie.value for cookie in self.cookies if cookie.name=='wr_vid'
                    and cookie.domain in ('.weread.qq.com','weread.qq.com') and cookie.path=='/'}
            if owners!={self.vid}:
                self.authenticated=False
                raise CbMetadataError('cb_metadata_owner_changed')
        check_owner()
        value=super().request(*args,**kwargs)
        check_owner()
        return value


def valid_errors(value):
    if not isinstance(value,dict):raise CbMetadataError('cb_metadata_invalid')
    for key in ('errcode','errCode'):
        if key in value and not (value[key] is None or type(value[key]) is int and value[key]==0):
            raise CbMetadataError('cb_metadata_rejected')
    if 'succ' in value and not (value['succ'] is True or type(value['succ']) is int and value['succ']==1):
        raise CbMetadataError('cb_metadata_rejected')


def inspect_channel(ids,read,*,native=False):
    samples=[];fields={}
    result=dict(verified=False,books=0,field_counts={})
    try:
        for identity in ids:
            source=read(identity)
            if native:
                valid_errors(source);expected=normalize_native(source,identity)
            else:
                expected=from_reader(source,identity)
                source=extract_initial_state(source)['reader']['bookInfo'];valid_errors(source)
            samples.append(dict(book_id=identity,source=source,expected=expected,native=native))
            for key in expected:fields[key]=fields.get(key,0)+1
        result['verified']=True
    except Exception:pass
    result.update(books=len(samples),field_counts=fields)
    return result,samples


def validate_catalog(value,identity):
    valid_errors(value) if isinstance(value,dict) else None
    entry,chapters=normalize_chapter_infos(value,identity)
    valid_errors(entry)
    rows=entry.get('updated') or entry.get('chapterInfos') or entry.get('chapters')
    if not isinstance(rows,list) or len(rows)!=len(chapters):raise CbMetadataError('cb_catalog_invalid')
    if not 1<=len(chapters)<=5000:raise CbMetadataError('cb_catalog_invalid')
    seen=set()
    for row in chapters:
        uid=identifier(row.get('chapterUid'))
        if uid in seen:raise CbMetadataError('cb_catalog_invalid')
        seen.add(uid)
    return len(chapters)


def stages(probe):
    return [{key:row[key] for key in ('stage','status','error_code','api_code') if key in row}
            for row in probe.report['stages']]


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--catalog',action='store_true')
    parser.add_argument('--lua-channel',choices=('native','web'))
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if (args.catalog and not args.saved_session or bool(args.lua_channel)!=bool(args.lua_command)
            or args.lua_command and not args.saved_session):parser.error('pair --lua-channel and --lua-command last; online options need --saved-session')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,
                authentication_posts=0,read_only_catalog_posts_attempted=0,private_metadata_or_credentials_saved=False,
                native_channel=dict(verified=False,books=0,field_counts={}),web_channel=dict(verified=False,books=0,field_counts={}))
    saved=credentials=native=web=None;sample_sets={}
    try:
        if args.saved_session:
            store=SessionStore();saved=store.load();credentials=NativeSessionStore().load(saved['vid'])
            native=CbNativeMetadataProbe()
            ids=cb_ids(native.request('metadata_shelf',NATIVE_BASE+'/shelf/sync',credentials=credentials))
            native.allowed_ids=set(ids)
            web=CbMetadataWebProbe();web.vid=saved['vid'];web.allowed=set(ids)
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account()
            if cb_ids(web.request('shelf',BASE+'/web/shelf/sync'))!=ids:raise CbMetadataError('cb_metadata_shelf_changed')
            report.update(same_owner_verified=True,cb_shelf_identities_match=True,cb_books=len(ids))
            report['native_channel'],sample_sets['native']=inspect_channel(ids,
                lambda identity:native.request('metadata',NATIVE_BASE+'/book/info?'+urlencode(dict(bookId=identity)),credentials=credentials),native=True)
            def reader(identity):
                web.book_id=identity
                return web.request('reader',reader_url_for(identity),as_json=False)
            report['web_channel'],sample_sets['web']=inspect_channel(ids,reader)
            if args.catalog:
                if not report['web_channel']['verified']:raise CbMetadataError('cb_catalog_reader_unverified')
                web.book_id=web.catalog_book=ids[0]
                report['read_only_catalog_posts_attempted']=1
                catalog=web.request('catalog_before',BASE+'/web/book/chapterInfos',{'bookIds':[ids[0]]})
                report.update(catalog_verified=True,catalog_books=1,catalog_chapters=validate_catalog(catalog,ids[0]))
            report['web_cookie_rotation_saved']=save_refreshed_web_session(store,saved,web)
            if args.lua_command:
                if not report[args.lua_channel+'_channel']['verified']:raise CbMetadataError('cb_metadata_channel_unverified')
                samples=sample_sets[args.lua_channel]
                payload=dict(cb_metadata=True,samples=samples)
                if args.lua_channel=='native':payload['native_credentials']=credentials
                else:
                    cookies={cookie.name:cookie.value for cookie in web.cookies if cookie.name in COOKIE_NAMES
                             and cookie.domain in ('.weread.qq.com','weread.qq.com') and cookie.path=='/'}
                    payload['session']=dict(vid=saved['vid'],cookies=cookies)
                encoded=json.dumps(payload,ensure_ascii=False).encode()
                if len(encoded)>2*1024*1024:raise CbMetadataError('cb_metadata_input_limit')
                child=subprocess.run(args.lua_command,input=encoded,capture_output=True,timeout=180)
                frame=b'\nWEREAD_METADATA_RESULT='
                if child.returncode or len(child.stdout)>2*1024*1024 or child.stdout.count(frame)!=1:
                    raise CbMetadataError('cb_metadata_lua_unverified')
                actual=json.loads(child.stdout.split(frame)[1]);expected=[sample['expected'] for sample in samples]
                if actual.get('model')!=expected or actual.get('native')!=expected or actual.get('requests')!=len(ids):
                    raise CbMetadataError('cb_metadata_lua_unverified')
                report.update(lua_channel=args.lua_channel,lua_model_and_https_match=True,lua_metadata_gets=len(ids))
            verified=[key for key in ('native','web') if report[key+'_channel']['verified']]
            if not verified:raise CbMetadataError('cb_metadata_unverified')
            report.update(result='CB_METADATA_READ_VERIFIED' if len(verified)==2 else 'CB_METADATA_PARTIAL_VERIFIED',verified_channels=verified)
    except Exception:report.update(result='UNVERIFIED',reason='cb_metadata_verification_failed')
    finally:
        if native:report['native_stages']=stages(native)
        if web:report['web_stages']=stages(web);web.close()
        if credentials:credentials.clear()
        if saved:saved.clear()
        sample_sets.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2))
    return 0 if report['result'] in ('OFFLINE_ONLY','CB_METADATA_READ_VERIFIED','CB_METADATA_PARTIAL_VERIFIED') else 1


if __name__=='__main__':raise SystemExit(main())
