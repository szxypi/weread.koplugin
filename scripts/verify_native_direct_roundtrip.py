#!/usr/bin/env python3
"""Bounded XHTML native position advance and exact restore; never replay a POST.

Offline by default. A dry run only reads. --apply records a two-write intent in
Keychain before its first POST. Results, identifiers and source stay private.
"""
import argparse
import hashlib
import json
import resource
import secrets
import time
from urllib.parse import urlencode

from fetch_weread_epub import decode_content_shards, make_content_params, read_reader_state, reader_url_for
from native_chapter_package import password, read, read_plain_tar
from native_txt_read_model import body
from readtime_upload_model import confirmed, guest_token, integer, local_zone
from secure_native_session import NativeSessionStore
from secure_native_txt_roundtrip import NativeTxtRoundtripStore, POINT_FIELDS, validate_binding
from secure_weread_session import SessionStore, StoreError
from shelf_flag_change_contract import state_hash
from txt_full_summary import digest
from verify_eink_login import BASE
from verify_native_chapter_package import ChapterProbe
from verify_native_txt_roundtrip import Probe
from verify_reader_progress import find_node, project
from verify_source_coordinates import CoordinateError, FilteredSource
from verify_web_source_progress import BASE as WEB, WebSourceProbe

PROTOCOL='native-direct-xhtml-zero-time-roundtrip-v1'


class DirectTrialStore(NativeTxtRoundtripStore):
    service='org.codex.weread.goal-native-direct-position-v1'
    protocol=PROTOCOL

    def validate_plan(self,plan):
        validate_binding(plan,self.protocol)
        before,target=plan['baseline'],plan['target']
        if (any(before[key]!=target[key] for key in POINT_FIELDS-{'chapter_offset','summary'})
                or before['chapter_offset']==target['chapter_offset'] or plan['chapter_progress'] is not None):
            raise StoreError('direct_roundtrip/plan')


class Reads(Probe):
    max_reads=64


def select_target(raw,before):
    model=FilteredSource(raw.decode('utf-8'),allow_multiple_bodies=True)
    for index in range(min(len(model.characters),10000)):
        char=model.characters[index];offset=model.starts[index]
        if char.isspace() or offset==before['chapter_offset']:continue
        try:text=model.anchor_at(offset,size=80)
        except CoordinateError:continue
        summary=''.join(c for c in text if not c.isspace())[:20]
        if len(summary)<20 or any(ord(c)<32 for c in summary):continue
        return dict(before,chapter_offset=offset,summary=summary)
    raise ValueError('direct_roundtrip/no_target')


def fields(point):
    return {key:point[key] for key in POINT_FIELDS}


def state(raw,identity,source):
    node=find_node(raw,identity);value=project(raw,identity,source)
    if (not any(key in node for key in ('chapterUid','chapterId','chapter_uid'))
            or not any(key in node for key in ('chapterIdx','chapterIndex','chapter_idx'))
            or not value['has_chapter_offset']):raise ValueError('direct_roundtrip/position')
    summary=node.get('summary')
    if not isinstance(summary,str) or not summary:raise ValueError('direct_roundtrip/summary')
    point=fields(dict(value,chapter_uid=str(value['chapter_uid']),summary=summary))
    counts={key:node.get(key) for key in ('readingTime','recordReadingTime','ttsTime')}
    if source=='native' and any(not integer(value,0,2**53-1) for value in counts.values()):
        raise ValueError('direct_roundtrip/counts')
    return point,counts


def current_source(sample,uid,credentials,web):
    txt=sample['expected'].get('format')=='txt'
    fields_=dict(bookId=sample['book_id'],chapters=uid if txt else '0,'+uid,bookType='txt' if txt else 'epub',
        bookVersion=sample['expected']['version'],
        pf='wechat_wx-2001-android-100-weread',pfkey='pfKey',zoneId=1,quote='',release=1,
        stopAutoPayWhenBNE=1,preload=2,preview=0,offline=1)
    probe=ChapterProbe();probe.archive_url=BASE+'/book/chapterdownload?'+urlencode(fields_)
    if txt:
        archive,_=probe.download(probe.archive_url,credentials,plain_text=True)
        native=read_plain_tar(archive,sample['book_id'],uid)
    else:
        archive,envelope=probe.download(probe.archive_url,credentials)
        decoded=read(archive,password(envelope,credentials['vid']),uid)
        if not decoded['html']:raise ValueError('direct_roundtrip/source')
        native=decoded['source']
    web.chapter=uid
    reader=read_reader_state(web.request('reader',reader_url_for(web.book_id,uid),as_json=False))
    params=make_content_params(web.book_id,uid,reader.psvts,sc=1)
    e0=web.request('e_0',WEB+'/web/book/chapter/e_0',params,as_json=False)
    if txt:
        from verify_txt_reading import fallback_marker
        if not fallback_marker(e0,sample['book_id'],uid):raise ValueError('direct_roundtrip/source')
        parts=[web.request(key,WEB+'/web/book/chapter/'+key,params,as_json=False) for key in ('t_0','t_1')]+['']
    else:
        parts=[e0]+[web.request(key,WEB+'/web/book/chapter/'+key,params,as_json=False) for key in ('e_1','e_3')]
    raw=decode_content_shards(*parts).encode()
    if raw!=native:raise ValueError('direct_roundtrip/source')
    return raw


def catalog(web,identity,uid,index):
    raw=web.request('catalog_before',WEB+'/web/book/chapterInfos',{'bookIds':[identity]})
    rows=raw.get('data') if isinstance(raw,dict) else None
    books=[item for item in rows or [] if isinstance(item,dict) and str(item.get('bookId'))==identity]
    if len(books)!=1 or not isinstance(books[0].get('updated'),list):raise ValueError('direct_roundtrip/catalog')
    selected=[item for item in books[0]['updated'] if isinstance(item,dict) and str(item.get('chapterUid'))==uid]
    if len(selected)!=1 or type(selected[0].get('chapterIdx')) is not int or selected[0]['chapterIdx']!=index:
        raise ValueError('direct_roundtrip/catalog')
    return digest(books[0]['updated'])


def check(web,native,credentials,identity,expected,counts,shelf_hash,web_shelf_hash,previous=None,*,both_counts=False):
    url=BASE+'/book/getProgress?'+urlencode(dict(bookId=identity))
    first,observed_counts=state(native.request('progress',url,credentials=credentials),identity,'native')
    second,web_counts=state(web.request('progress_after',WEB+'/web/book/getProgress?'+urlencode(dict(bookId=identity))),identity,'web')
    if (observed_counts!=counts or both_counts and (web_counts!=counts
            or any(not integer(value,0,2**53-1) for value in web_counts.values()))
            or any(point!=expected and (previous is None or point!=previous) for point in (first,second))):
        raise ValueError('direct_roundtrip/changed')
    if state_hash(native.request('shelf',BASE+'/shelf/sync',credentials=credentials))!=shelf_hash:
        raise ValueError('direct_roundtrip/shelf')
    if state_hash(web.request('shelf',WEB+'/web/shelf/sync'))!=web_shelf_hash:raise ValueError('direct_roundtrip/shelf')
    return first==expected and second==expected


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--apply',action='store_true')
    parser.add_argument('--book-offset',type=int,choices=range(51),default=15)
    args=parser.parse_args(argv)
    if args.apply and not args.saved_session:parser.error('saved session required')
    report={'result':'OFFLINE_ONLY','account_data_posts':0,'authentication_posts':0,'web_write_posts':0}
    if not args.saved_session:
        print(json.dumps(report));return 0
    saved=credentials=web=store=None;receipt=None;phase='credentials';attempted=0
    try:
        resource.setrlimit(resource.RLIMIT_CORE,(0,0))
        from verify_native_thought_trial import other_pending
        if other_pending():raise ValueError('direct_roundtrip/other_pending')
        store=DirectTrialStore()
        if store.read()[0] is not None:raise ValueError('direct_roundtrip/consumed')
        saved=SessionStore().load();credentials=NativeSessionStore().load(saved['vid'])
        phase='source';probe=ChapterProbe();sample,_chapter,_initial=probe.inspect(credentials,args.book_offset)
        if sample['expected']['format']!='epub':raise ValueError('direct_roundtrip/format')
        identity=sample['book_id'];native=Reads(credentials,identity)
        raw=native.request('progress',BASE+'/book/getProgress?'+urlencode(dict(bookId=identity)),credentials=credentials)
        before,counts=state(raw,identity,'native')
        candidates=[row for row in sample['expected']['chapters'] if str(row['uid'])==before['chapter_uid']
            and row.get('free_or_owned') and row.get('wordCount',0)>=200]
        if len(candidates)!=1:raise ValueError('direct_roundtrip/chapter')
        web=WebSourceProbe();web.vid=saved['vid']
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();web.book_id=identity;web.chapter=before['chapter_uid']
        catalog_hash=catalog(web,identity,before['chapter_uid'],before['chapter_idx'])
        source=current_source(sample,before['chapter_uid'],credentials,web);target=select_target(source,before)
        if catalog(web,identity,before['chapter_uid'],before['chapter_idx'])!=catalog_hash:raise ValueError('direct_roundtrip/catalog')
        shelf_hash=state_hash(native.request('shelf',BASE+'/shelf/sync',credentials=credentials))
        web_shelf_hash=state_hash(web.request('shelf',WEB+'/web/shelf/sync'))
        guest,_=guest_token(native.request('feature',BASE+'/feature?synckey=0',credentials=credentials))
        plan=dict(protocol=PROTOCOL,owner_sha256=digest(saved['vid']),source_sha256=hashlib.sha256(source).hexdigest(),
            catalog_sha256=catalog_hash,grant_sha256=digest(credentials),shelf_sha256=shelf_hash,
            baseline=before,target=target,counts=counts,version=sample['expected']['version'],chapter_progress=None)
        store.validate_plan(plan);check(web,native,credentials,identity,before,counts,shelf_hash,web_shelf_hash)
        report.update(result='READ_ONLY_READY',source_matches=True,source_target_unique=True,cloud_baseline_matches=True)
        if not args.apply:return 0
        phase='prepared';receipt=store.reserve(plan)
        for seq,(prior,wanted) in enumerate(((before,target),(target,before)),1):
            phase='advance' if seq==1 else 'restore'
            if digest(NativeSessionStore().load(saved['vid']))!=plan['grant_sha256'] or SessionStore().load()['vid']!=saved['vid']:
                raise ValueError('direct_roundtrip/grant')
            fresh=current_source(sample,before['chapter_uid'],credentials,web)
            if hashlib.sha256(fresh).hexdigest()!=plan['source_sha256']:raise ValueError('direct_roundtrip/source')
            if catalog(web,identity,before['chapter_uid'],before['chapter_idx'])!=catalog_hash:raise ValueError('direct_roundtrip/catalog')
            check(web,native,credentials,identity,prior,counts,shelf_hash,web_shelf_hash)
            request=body(credentials,wanted,plan['version'],guest,int(time.time()),secrets.randbelow(1000),local_zone())
            native.pending=digest(request)
            def claim():
                nonlocal receipt,attempted
                receipt=store.advance(receipt,'prepared' if seq==1 else 'advance_verified',
                    'advance_pending' if seq==1 else 'restore_pending')
                attempted=seq
            native.claim=claim
            ack=native.request('native_txt_advance' if seq==1 else 'native_txt_restore',BASE+'/book/read',body=request,credentials=credentials)
            if not confirmed(ack):raise ValueError('direct_roundtrip/ack')
            receipt=store.advance(receipt,'advance_pending' if seq==1 else 'restore_pending',
                'advance_acknowledged' if seq==1 else 'restore_acknowledged')
            # Readback is never a reason to repeat a POST.
            settled=False
            for attempt in range(4):
                if check(web,native,credentials,identity,wanted,counts,shelf_hash,web_shelf_hash,previous=prior):
                    settled=True;break
                if attempt<3:time.sleep(1)
            if not settled:raise ValueError('direct_roundtrip/readback_pending')
            receipt=store.advance(receipt,'advance_acknowledged' if seq==1 else 'restore_acknowledged',
                'advance_verified' if seq==1 else 'retired')
        report.update(result='NATIVE_XHTML_ROUNDTRIP_VERIFIED',explicit_success_receipts=2,
            independent_readbacks=2,original_position_restored=True,counts_and_shelf_unchanged=True)
    except Exception as error:
        report.update(result='UNVERIFIED',phase=phase)
        if isinstance(error,(ValueError,StoreError)) and str(error).startswith('direct_roundtrip/'):
            report['reason']=str(error)
    finally:
        report['account_data_posts']=attempted
        if web:web.close()
        if saved:saved.clear()
        if credentials:credentials.clear()
        print(json.dumps(report))
    return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
