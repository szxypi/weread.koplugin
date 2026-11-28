#!/usr/bin/env python3
"""Real CB XHTML guarded source/current-position check, read-only and offline by default."""
import argparse
import json
import re
import resource
import subprocess

from cb_cloud_position import observed,state
from secure_weread_session import SessionStore
from verify_cb_cloud_position import Web
from verify_reader_progress import project
from verify_cb_progress import cb_ids
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE,WebSourceProbe


def descriptor(sample,point):
    if sample.get('source_format')!='web_xhtml' or point.get('kind')!='located':return None
    book,uid=sample['book_id'],sample['chapter_uid']
    if uid!=point.get('chapter_uid'):return None
    selected=[]
    for row in sample['chapters']:
        if not isinstance(row,dict):return None
        ids=[str(row[k]) for k in ('chapterUid','chapterId','chapter_uid') if k in row]
        if not ids or any(re.fullmatch('[1-9][0-9]{0,19}',x) is None for x in ids) or len(set(ids))!=1:return None
        if ids[0]==uid:
            indices=[row[k] for k in ('chapterIdx','chapterIndex','chapter_idx') if k in row]
            if not indices or any(type(x) is not int or not 0<=x<=1000000 for x in indices) or len(set(indices))!=1:return None
            selected.append(indices[0])
    if len(selected)!=1 or selected[0]!=point['chapter_idx']:return None
    return dict(book_id=book,chapter_uid=uid,chapter_idx=selected[0],raw_sha256=sample['source_raw_sha256'],
                raw_bytes=len(sample['source'].encode()))


class CheckFailure(ValueError):
    def __init__(self,reason,requests,line):
        self.reason=reason;self.requests=requests;self.line=line
        super().__init__('cb_currentness/lua')


def compare(command,expected,remote,saved):
    payload=dict(expected=expected,remote=remote,vid=saved['vid'],cookies=saved['cookies'])
    child=subprocess.run(command,input=json.dumps(payload).encode(),capture_output=True,timeout=90)
    frame=b'\nWEREAD_CB_GUARDED_CURRENTNESS='
    if len(child.stdout)>65536 or child.stdout.count(frame)!=1:raise ValueError('cb_currentness/lua')
    result=json.loads(child.stdout.split(frame,1)[1].splitlines()[0])
    if child.returncode:
        allowed={'expected','catalog','catalog_changed','reader','source_invalid','source_changed','web_required',
                 'session_changed','web_expired','unavailable','response','owner','remote_changed','probe'}
        reason=result.get('reason') if isinstance(result,dict) else None
        count=result.get('requests') if isinstance(result,dict) else None
        line=result.get('line') if isinstance(result,dict) else None
        raise CheckFailure(reason if reason in allowed else 'probe',count if type(count) is int and 0<=count<=10 else 0,
                           line if type(line) is int and 0<=line<=200 else 0)
    if result!=dict(matched=True,requests=10,upload_disabled=True,numeric_gate_preserved=True):raise ValueError('cb_currentness/result')
    return True


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    if args.saved_session and not args.lua_command or args.lua_command and not args.saved_session:
        parser.error('explicit session and Lua command must be supplied together')
    report=dict(result='OFFLINE_ONLY',books=0,eligible=0,lua_matches=0,account_data_writes=0,authentication_writes=0,
                private_data_in_report=False,write_authority_granted=False)
    if not args.saved_session:
        print(json.dumps(report));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    saved=web=after=None;snapshots=[]
    try:
        store=SessionStore();saved=store.load();web=Web();web.vid=saved['vid']
        for k,v in saved['cookies'].items():web.set_cookie(k,v)
        web.verify_account();shelf=web.request('shelf',BASE+'/web/shelf/sync');ids=cb_ids(shelf);web.allowed=set(ids)
        web.shelf_ids=[str(row['bookId']) for row in shelf['books']];web.shelf_count=len(shelf['books'])
        for book in ids:
            sample=web.inspect(book);raw=web.progress[(book,'progress_before')]
            point=state(raw,book,sample['chapters'],'web')
            snapshots.append((book,sample['chapters'],observed(raw,book,sample['chapters'],'web')))
            expected=descriptor(sample,point)
            if expected:
                report['eligible']+=1
                if save_refreshed_web_session(store,saved,web):
                    old=saved;saved=store.load()
                    if saved['vid']!=old['vid']:raise ValueError('cb_currentness/owner')
                    old.clear()
                p=project(raw,book,'web')
                remote=dict(book_id=book,source='web',chapter_uid=expected['chapter_uid'],chapter_idx=expected['chapter_idx'],
                    chapter_offset=p['chapter_offset'],raw_percent=p['raw_percent'],updated_at=p['updated_at'],
                    has_chapter_index=True,has_chapter_offset=True)
                compare(args.lua_command,expected,remote,saved);report['lua_matches']+=1
            report['books']+=1
        if not report['eligible']:raise ValueError('cb_currentness/no_samples')
        web.verify_account()
        if save_refreshed_web_session(store,saved,web):
            old=saved;saved=store.load()
            if saved['vid']!=old['vid']:raise ValueError('cb_currentness/owner')
            old.clear()
        after=WebSourceProbe();after.vid=saved['vid']
        for k,v in saved['cookies'].items():after.set_cookie(k,v)
        after.verify_account()
        for book,chapters,baseline in snapshots:
            after.book_id=book
            latest=after.request('progress_after',BASE+'/web/book/getProgress?bookId='+book)
            if observed(latest,book,chapters,'web')!=baseline:raise ValueError('cb_currentness/position')
        last=after.request('shelf',BASE+'/web/shelf/sync');after.verify_account()
        if [str(row['bookId']) for row in last['books']]!=web.shelf_ids:raise ValueError('cb_currentness/shelf')
        report.update(result='CB_GUARDED_CURRENTNESS_VERIFIED',positions_unchanged=True,shelf_order_unchanged=True)
    except CheckFailure as error:report.update(result='UNVERIFIED',failure_reason=error.reason,failure_requests=error.requests,failure_line=error.line)
    except Exception:report['result']='UNVERIFIED'
    finally:
        if web:
            if not after and saved and web.authenticated:
                try:save_refreshed_web_session(store,saved,web)
                except Exception:report['result']='UNVERIFIED'
            web.samples.clear();web.progress.clear();web.close()
        if after:
            if saved and after.authenticated:
                try:save_refreshed_web_session(store,saved,after)
                except Exception:report['result']='UNVERIFIED'
            after.close()
        if saved:saved.clear()
        snapshots.clear()
    print(json.dumps(report));return int(report['result']!='CB_GUARDED_CURRENTNESS_VERIFIED')


if __name__=='__main__':raise SystemExit(main())
