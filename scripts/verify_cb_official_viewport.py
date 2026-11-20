#!/usr/bin/env python3
"""Compare one CB_ resume position to the official reader without writes.

Default is offline. Explicit session mode opens one isolated browser using the
saved account, bounds network traffic to the chosen book's reads, and blocks
progress, authorization and all other writes. Outputs contain only counts and
booleans; private source and account details remain in process memory.
"""
import argparse
import json
import resource
import subprocess

from cb_cloud_position import observed, state
from cb_official_viewport import observe
from secure_weread_session import SessionStore
from verify_source_coordinates import CoordinateError,FilteredSource
from verify_cb_cloud_position import Web
from verify_cb_progress import cb_ids
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE, WebSourceProbe


def anchors_for(source,offset):
    model=FilteredSource(source,allow_multiple_bodies=True)
    target=[i for i,start in enumerate(model.starts) if start==offset]
    relation='exact'
    if len(target)!=1:
        # Diagnostic only: the official renderer may land on the next text
        # after a tag or an entity. This never changes the cloud position.
        target=[i for i,start in enumerate(model.starts) if offset<start<=offset+1024][:1]
        relation='following'
    if len(target)!=1:return [],'unavailable'
    try:anchor=model.anchor_at(model.starts[target[0]])
    except CoordinateError:return [],'unavailable'
    values=[anchor];used=[target[0]];length=len(model.starts)
    for fraction in (0.1,0.5,0.9,0.25,0.75):
        index=min(length-1,int(length*fraction))
        if any(abs(index-old)<max(150,length//10) for old in used):continue
        try:control=model.anchor_at(model.starts[index])
        except CoordinateError:continue
        if control in values:continue
        values.append(control);used.append(index)
        if len(values)==3:break
    return values,relation


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--book-index',type=int,choices=range(1,9),default=1)
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if args.lua_command and not args.saved_session:parser.error('Lua comparison requires saved session')
    report=dict(result='OFFLINE_ONLY',account_data_writes=0,authentication_writes=0,
                source_contents_in_report=False,book_identifiers_in_report=False)
    if not args.saved_session:
        print(json.dumps(report));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    saved=web=after=None
    try:
        store=SessionStore();saved=store.load();web=Web();web.vid=saved['vid']
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();shelf=web.request('shelf',BASE+'/web/shelf/sync');ids=cb_ids(shelf)
        if args.book_index>len(ids):raise ValueError('viewport/book_index')
        book=ids[args.book_index-1];web.allowed=set(ids)
        web.shelf_ids=[str(row['bookId']) for row in shelf['books']];web.shelf_count=len(shelf['books'])
        sample=web.inspect(book)
        point=state(web.progress[(book,'progress_before')],book,sample['chapters'],'web')
        if point.get('kind')!='located' or point['chapter_uid']!=sample['chapter_uid']:
            raise ValueError('viewport/no_position')
        original=observed(web.progress[(book,'progress_before')],book,sample['chapters'],'web')
        web.verify_account()
        if save_refreshed_web_session(store,saved,web):
            previous=saved;saved=store.load()
            if saved['vid']!=previous['vid']:raise ValueError('viewport/owner_changed')
            previous.clear()
        anchors,relation=anchors_for(sample['source'],point['chapter_offset'])
        result=observe(book,[row['chapterUid'] for row in sample['chapters']],saved['cookies'],point['chapter_offset'],source_anchors=anchors or None)
        lua_verified=False
        if args.lua_command:
            payload=dict(book=book,chapter=sample['chapter_uid'],offset=point['chapter_offset'],
                         source_sha256=sample['source_raw_sha256'],vid=saved['vid'],cookies=saved['cookies'])
            child=subprocess.run(args.lua_command,input=json.dumps(payload).encode(),capture_output=True,timeout=90)
            frame=b'\nWEREAD_CB_CLOUD_READ='
            if child.returncode or child.stdout.count(frame)!=1 or len(child.stdout)>65536:
                raise ValueError('viewport/lua_failed')
            if json.loads(child.stdout.split(frame,1)[1])!={'matched':True,'requests':6}:
                raise ValueError('viewport/lua_mismatch')
            lua_verified=True
        after=WebSourceProbe();after.vid=saved['vid'];after.book_id=book;after.chapter=sample['chapter_uid']
        for key,value in saved['cookies'].items():after.set_cookie(key,value)
        after.verify_account()
        latest=after.request('progress_after',BASE+'/web/book/getProgress?bookId='+book)
        final_shelf=after.request('shelf',BASE+'/web/shelf/sync')
        after.verify_account()
        if observed(latest,book,sample['chapters'],'web')!=original or [str(x['bookId']) for x in final_shelf['books']]!=web.shelf_ids:
            raise ValueError('viewport/state_changed')
        if save_refreshed_web_session(store,saved,after):
            previous=saved;saved=store.load()
            if saved['vid']!=previous['vid']:raise ValueError('viewport/owner_changed')
            previous.clear()
        report.update(result='VIEWPORT_OBSERVED',position_unchanged=True,shelf_order_unchanged=True,
                      chapter_and_source_verified=True,source_anchor_relation=relation,controls=len(anchors)-1 if anchors else 0,
                      lua_cloud_source_verified=lua_verified,**result)
    except Exception:
        report['result']='UNVERIFIED'
    finally:
        if web:web.samples.clear();web.progress.clear();web.close()
        if after:
            if saved and after.authenticated:
                try:save_refreshed_web_session(store,saved,after)
                except Exception:report['result']='UNVERIFIED'
            after.close()
        if saved:saved.clear()
    print(json.dumps(report));return 0 if report['result']=='VIEWPORT_OBSERVED' else 1


if __name__=='__main__':raise SystemExit(main())
