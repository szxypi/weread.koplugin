#!/usr/bin/env python3
"""Verify real-account native CB missing-chapter download and cloud-view UI.

Offline by default. The explicit saved-session mode reads a single CB chapter
and position, then passes source, coordinates and session via stdin to a scoped
read-only UI runner. The fresh-process offline stage is network-blocked. Credentials and private text never appear in its result.
"""
import argparse
import json
import resource
import subprocess

from cb_cloud_position import mapping,observed,state
from secure_weread_session import SessionStore
from verify_cb_cloud_position import Web
from verify_cb_progress import cb_ids
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE,WebSourceProbe


def run_ui(command,payload,single,width,height,dpi):
    args=[*command,'--width',str(width),'--height',str(height),'--dpi',str(dpi)]
    if single:args.append('--single')
    child=subprocess.run(args,input=json.dumps(payload,ensure_ascii=False).encode(),stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE,timeout=360)
    if child.returncode or len(child.stdout)>4096:raise ValueError('owner_cb/ui')
    report=json.loads(child.stdout)
    gets,posts=report.get('download_gets'),report.get('download_posts')
    if type(gets) is not int or not 1<=gets<=4 or type(posts) is not int or not 1<=posts<=8:
        raise ValueError('owner_cb/download_counts')
    expected=dict(result='PASS',profile_removed=True,installed_bytes_match=True,native_navigation=True,
                  fresh_process=True,pending_preserved=True,upload_disabled=True,requests=18,denied=0,
                  credentials_not_persisted=True,cancel_without_download=True,download_confirmed=True,
                  downloaded_source_verified=True,credential_audit=True,download_gets=gets,download_posts=posts)
    if report!=expected:raise ValueError('owner_cb/result')
    return dict(single=single,width=width,height=height,**report)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--book-index',type=int,choices=range(1,9),default=1)
    parser.add_argument('--runner',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if args.saved_session and not args.runner:parser.error('saved session requires explicit isolated runner')
    if args.runner and not args.saved_session:parser.error('runner requires saved session')
    report=dict(result='OFFLINE_ONLY',account_data_writes=0,authentication_writes=0,
                private_data_in_report=False,ui_requests_scope_limited=True,stages=[])
    if not args.saved_session:
        print(json.dumps(report));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    saved=web=after=None;phase='session'
    try:
        store=SessionStore();saved=store.load();web=Web();web.vid=saved['vid']
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();shelf=web.request('shelf',BASE+'/web/shelf/sync');ids=cb_ids(shelf)
        if args.book_index>len(ids):raise ValueError('owner_cb/book')
        book=ids[args.book_index-1];web.allowed=set(ids)
        web.shelf_ids=[str(row['bookId']) for row in shelf['books']];web.shelf_count=len(shelf['books'])
        phase='source';sample=web.inspect(book)
        baseline=web.progress[(book,'progress_before')]
        point=state(baseline,book,sample['chapters'],'web')
        match=mapping(sample['source'],sample['chapter_uid'],point)
        if (sample['source_format']!='web_xhtml' or point.get('kind')!='located' or not match['chapter_matches']
                or not match['unique_anchor'] or not isinstance(point['raw_percent'],(int,float))):
            raise ValueError('owner_cb/position')
        original=observed(baseline,book,sample['chapters'],'web')
        web.verify_account()
        if save_refreshed_web_session(store,saved,web):
            previous=saved;saved=store.load()
            if saved['vid']!=previous['vid']:raise ValueError('owner_cb/owner')
            previous.clear()
        payload=dict(book=book,chapter=sample['chapter_uid'],source=sample['source'],
                     offset=point['chapter_offset'],percent=point['raw_percent'],owner=saved['vid'],cookies=saved['cookies'])
        phase='ui'
        for width,height,dpi in ((600,800,167),(1264,1680,300)):
            report['stages'].append(run_ui(args.runner,payload,True,width,height,dpi))
        phase='after'
        after=WebSourceProbe();after.vid=saved['vid'];after.book_id=book;after.chapter=sample['chapter_uid']
        for key,value in saved['cookies'].items():after.set_cookie(key,value)
        after.verify_account()
        latest=after.request('progress_after',BASE+'/web/book/getProgress?bookId='+book)
        final_shelf=after.request('shelf',BASE+'/web/shelf/sync');after.verify_account()
        if observed(latest,book,sample['chapters'],'web')!=original or [str(x['bookId']) for x in final_shelf['books']]!=web.shelf_ids:
            raise ValueError('owner_cb/changed')
        report.update(result='PASS',position_unchanged=True,shelf_order_unchanged=True)
    except Exception:
        report.update(result='UNVERIFIED',failure_stage=phase)
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
    print(json.dumps(report));return int(report['result']!='PASS')


if __name__=='__main__':raise SystemExit(main())
