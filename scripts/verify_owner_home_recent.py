#!/usr/bin/env python3
"""Read-only real-account off-shelf reading and native home resume acceptance.

Offline by default. Credentials, identifiers and source text travel only through
captured memory pipes to an isolated tmpfs profile; no account data writes or
authorization POSTs are admitted. The book is selected from fixed public queries.
"""
import argparse
import hashlib
import json
import resource
import subprocess
from urllib.parse import urlencode

from fetch_weread_epub import decode_content_shards,make_content_params,normalize_chapter_infos,read_reader_state,reader_url_for
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from shelf_flag_change_contract import state_hash
from translation_observation import observation
from verify_eink_login import BASE as NATIVE_BASE
from verify_owner_reading import SourceText,decode_envelope
from verify_source_coordinates import FilteredSource
from verify_translation_preflight import PUBLIC_QUERIES,TranslationError,TranslationProbe,save_refreshed_web_session
from verify_my_cloud_marks import MarksProbe
from my_cloud_marks_model import project as marks_project
from verify_web_source_progress import BASE,PreflightError,WebSourceProbe


class Probe(WebSourceProbe):
    def guard(self,stage,url,body):
        if stage=='reader_root' and self.authenticated and self.book_id and body is None and url==reader_url_for(self.book_id):return
        return super().guard(stage,url,body)


def ids(shelf):
    rows=shelf.get('books') if isinstance(shelf,dict) else None
    if not isinstance(rows,list) or not 0<len(rows)<=5000:raise ValueError('home/shelf')
    result=[]
    for row in rows:
        if not isinstance(row,dict):raise ValueError('home/shelf')
        value=row.get('bookId')
        if not isinstance(value,str):value=str(value) if type(value) is int else ''
        if not value or len(value)>100 or any(not (c.isascii() and (c.isalnum() or c=='_')) for c in value):raise ValueError('home/shelf')
        if value in result:raise ValueError('home/shelf')
        result.append(value)
    return result


def candidate(web,sample):
    book=sample['book_id'];web.book_id=book;web.chapter=None
    initial=observation(web.request('progress_before',BASE+'/web/book/getProgress?'+urlencode(dict(bookId=book))),book,'web')
    root=read_reader_state(web.request('reader_root',reader_url_for(book),as_json=False))
    uid=str(root.current_chapter.get('chapterUid') or '')
    if root.book_id!=book or not uid.isascii() or not uid.isdigit() or uid=='0' or len(uid)>20:return None
    chapter=next((row for row in sample['expected']['chapters'] if str(row['uid'])==uid),None)
    if not chapter or chapter.get('free_or_owned') is not True:return None
    web.chapter=uid
    catalog=web.request('catalog_before',BASE+'/web/book/chapterInfos',{'bookIds':[book]})
    _record,rows=normalize_chapter_infos(catalog,book)
    selected=[row for row in rows if str(row.get('chapterUid'))==uid and type(row.get('wordCount')) is int
              and row['wordCount']>0 and str(row.get('title',''))!='封面']
    if len(selected)!=1:return None
    state=read_reader_state(web.request('reader',reader_url_for(book,uid),as_json=False))
    if state.book_id!=book or str(state.current_chapter.get('chapterUid'))!=uid or not state.psvts:return None
    params=make_content_params(book,uid,state.psvts,sc=1)
    shards=[web.request(name,BASE+'/web/book/chapter/'+name,params,as_json=False) for name in ('e_0','e_1','e_3')]
    source=decode_content_shards(*shards)
    if not isinstance(source,str) or not 0<len(source.encode())<=2*1024*1024:return None
    text=SourceText();text.feed(source);model=FilteredSource(source);chosen=None
    for excerpt in text.samples:
        try:offset=model.locate(excerpt)[0]
        except Exception:continue
        chosen=(excerpt,offset);break
    if not chosen:return None
    if web.request('catalog_after',BASE+'/web/book/chapterInfos',{'bookIds':[book]})!=catalog:return None
    if observation(web.request('progress_after',BASE+'/web/book/getProgress?'+urlencode(dict(bookId=book))),book,'web')!=initial:return None
    title,author=root.book_title,root.author
    if not isinstance(title,str) or not 0<len(title.encode())<=1024 or not isinstance(author,str) or len(author.encode())>1024:return None
    return dict(book_id=book,chapter_uid=uid,source_text=chosen[0],source_sample_offset=chosen[1],
        source_raw_sha256=hashlib.sha256(source.encode()).hexdigest(),source_format='web_xhtml',
        off_shelf_row=dict(bookId=book,title=title,author=author),off_shelf_home=True),initial


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--store-search',action='store_true',help='Exercise native bookstore search before reading')
    parser.add_argument('--with-cover',action='store_true',help='Verify selected-book cover on store and home')
    parser.add_argument('--with-marks',action='store_true',help='Verify personal mark snapshot in the native reader')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if bool(args.saved_session)!=bool(args.lua_command) or args.store_search and not args.saved_session:
        parser.error('pair --saved-session with --lua-command last; store search requires that pair')
    if args.with_cover and not args.store_search:parser.error('--with-cover requires --store-search')
    if args.with_marks and not args.store_search:parser.error('--with-marks requires --store-search')
    report=dict(result='OFFLINE_ONLY',account_data_writes=0,authentication_posts=0,private_data_on_regular_disk=False,screenshots=0)
    if not args.saved_session:print(json.dumps(report));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    saved=grant=web=payload=envelope=None;phase='session';report['result']='UNVERIFIED'
    try:
        store=SessionStore();saved=store.load();grant=NativeSessionStore().load(saved['vid']);web=Probe();web.vid=saved['vid']
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();phase='shelf'
        shelf=web.request('shelf',BASE+'/web/shelf/sync');shelf_ids=ids(shelf);web_before=state_hash(shelf)
        native=TranslationProbe();native_before=state_hash(native.request('shelf',NATIVE_BASE+'/shelf/sync',credentials=grant))
        native_ids=set(ids(native.request('shelf',NATIVE_BASE+'/shelf/sync',credentials=grant)))
        phase='candidate';checked=0
        for query in PUBLIC_QUERIES[:3]:
            api=TranslationProbe(public_query=query)
            try:api.inspect(grant,2,True)
            except TranslationError as error:
                if str(error)=='translation/no_eligible_sample':continue
                raise
            for sample in api.samples:
                if sample['book_id'] in shelf_ids or sample['book_id'] in native_ids:continue
                checked+=1
                try:value=candidate(web,sample)
                except ValueError:continue
                if value:payload,baseline=value;selected_query=query;break
            if payload:break
        if not payload:raise ValueError('home/no_candidate')
        if args.with_marks:
            marks=MarksProbe();marks.identity=payload['book_id']
            marks_url=NATIVE_BASE+'/book/bookmarklist?'+urlencode(dict(bookId=marks.identity,synckey=0))
            mark_model=marks_project(marks.request('marks',marks_url,credentials=grant),marks.identity,saved['vid'],1)
            if len(json.dumps(mark_model,ensure_ascii=False).encode())>128*1024:raise ValueError('home/marks_limit')
        web.book_id=None;web.chapter=None
        if ids(web.request('shelf',BASE+'/web/shelf/sync'))!=shelf_ids:raise ValueError('home/shelf_changed')
        if store.load()!=saved or NativeSessionStore().load(saved['vid'])!=grant:raise ValueError('home/session_changed')
        save_refreshed_web_session(store,saved,web);saved=store.load()
        payload.update(vid=web.vid,cookies=saved['cookies'],shelf_ids=shelf_ids,shelf_books=len(shelf_ids))
        if args.store_search:payload.update(off_shelf_store=True,store_search_keyword=selected_query,native_grant=grant)
        if args.with_cover:payload['off_shelf_cover']=True
        if args.with_marks:payload.update(off_shelf_marks=True,native_marks_expected=mark_model)
        phase='native'
        child=subprocess.run(args.lua_command,input=json.dumps(payload,ensure_ascii=False).encode(),capture_output=True,timeout=340)
        envelope=decode_envelope(child.stdout,web.vid,off_shelf_home=True,off_shelf_store=args.store_search,off_shelf_cover=args.with_cover,off_shelf_marks=args.with_marks)
        web.cookies.clear()
        for key,value in envelope['cookies'].items():web.set_cookie(key,value)
        web.verify_account();web.book_id=payload['book_id'];web.chapter=payload['chapter_uid']
        after=observation(web.request('progress_after',BASE+'/web/book/getProgress?'+urlencode(dict(bookId=web.book_id))),web.book_id,'web')
        web.book_id=None;web.chapter=None
        final_shelf=web.request('shelf',BASE+'/web/shelf/sync')
        native_after=state_hash(native.request('shelf',NATIVE_BASE+'/shelf/sync',credentials=grant))
        if args.with_marks and marks_project(marks.request('marks',marks_url,credentials=grant),marks.identity,saved['vid'],1)!=mark_model:
            raise ValueError('home/marks_changed')
        if (after!=baseline or ids(final_shelf)!=shelf_ids or state_hash(final_shelf)!=web_before or native_after!=native_before
                or store.load()!=saved or NativeSessionStore().load(saved['vid'])!=grant):raise ValueError('home/baseline_changed')
        web.verify_account();save_refreshed_web_session(store,saved,web)
        report.update(result='OWNER_OFF_SHELF_HOME_VERIFIED',candidate_books_checked=checked,shelf_books=len(shelf_ids),
                      shelf_and_observed_position_unchanged=True,ui=envelope['report'])
        if args.store_search:report['store_search_verified']=True
        if args.with_cover:report['selected_cover_verified']=True
        if args.with_marks:report.update(personal_marks_verified=True,marks_count=len(mark_model['updated']))
        if child.returncode or envelope['report']['result']!='PASS':raise ValueError('home/native_failed')
    except Exception as error:
        report.update(result='UNVERIFIED',phase=phase,error_type=type(error).__name__)
        if isinstance(error,PreflightError) and str(error) in ('http_rejected','api_rejected','connection_failed','request_timed_out'):
            report['reason']=str(error)
        if web and web.report.get('stages'):
            report['last_web_stage']={k:web.report['stages'][-1][k] for k in ('stage','status','api_code') if k in web.report['stages'][-1]}
    finally:
        if web:web.close()
        for value in (saved,grant,payload,envelope):
            if isinstance(value,dict):value.clear()
    print(json.dumps(report,ensure_ascii=False))
    return int(report['result']!='OWNER_OFF_SHELF_HOME_VERIFIED')


if __name__=='__main__':raise SystemExit(main())
