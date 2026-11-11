#!/usr/bin/env python3
"""One missing chapter -> confirmed native download -> exact note source.

Offline by default. Live source/credentials only cross captured pipes and a
deleted tmpfs profile. Existing catalog/content read POSTs only; no data writes.
"""
import argparse
from datetime import datetime,timezone
import json
import re
import subprocess
import time
from urllib.parse import urlencode

from my_cloud_marks_model import project as marks_project,integer,text
from my_mark_target import project as mark_target
from my_thought_target import project as thought_target
from personal_notes_position import unchanged,response_clock_matches
from secure_weread_session import SessionStore,COOKIE_NAMES
from secure_native_session import NativeSessionStore
from source_currentness import inspect,FIELDS
from verify_my_mark_target import TargetMarksProbe
from verify_my_thought_target import TargetThoughtsProbe,read_all
from verify_translation_preflight import save_refreshed_web_session
from verify_owner_reading import validate_cookies
from verify_eink_login import BASE as NATIVE
from verify_web_source_progress import WebSourceProbe,BASE,position
from run_my_mark_navigation_ui import DOWNLOAD_FRAME,public_report,validate


def selection(model,kind):
    rows=model['reviews' if kind=='thoughts' else 'updated'];selected=[]
    for row in rows:
        quote=row.get('abstract' if kind=='thoughts' else 'markText');marker=row.get('range')
        match=re.fullmatch(r'([0-9]{1,10})-([0-9]{1,10})',marker) if isinstance(marker,str) else None
        if (row.get('type')==1 and type(row.get('type')) is int and integer(row.get('chapterUid'),2147483647) and row['chapterUid']>0
                and text(quote,65536 if kind=='thoughts' else 131072,False) and quote.strip()
                and match and 0<=int(match[1])<int(match[2])<=2147483647):selected.append(row)
    if not selected:raise ValueError('note_download/no_quote')
    uid=min(row['chapterUid'] for row in selected)
    return str(uid),[row for row in selected if row['chapterUid']==uid][:3]


def snapshot_after(notes,credentials,kind,model):
    if kind=='thoughts':value=read_all(notes,credentials)
    else:
        raw=notes.request('final_marks',NATIVE+'/book/bookmarklist?'+urlencode(dict(bookId=notes.identity,synckey=0)),credentials=credentials)
        value=marks_project(raw,notes.identity,credentials['vid'],model['fetched_at'])
    value['fetched_at']=model['fetched_at']
    if value!=model:raise ValueError('note_download/notes_changed')
    stage='progress_after' if kind=='thoughts' else 'final_position'
    started=time.time();raw=notes.request(stage,NATIVE+'/book/getProgress?'+urlencode(dict(bookId=notes.identity)),credentials=credentials)
    before=notes.before if kind=='thoughts' else notes.baseline
    if not response_clock_matches(raw,started,time.time()) or not unchanged(before,raw,notes.identity):raise ValueError('note_download/position_changed')


def current_cookies(web,owner):
    return validate_cookies({cookie.name:cookie.value for cookie in web.cookies if cookie.name in COOKIE_NAMES
                            and cookie.domain in ('.weread.qq.com','weread.qq.com') and cookie.path=='/'},owner)


def validate_ui(value,count):
    if (not isinstance(value,dict) or set(value)!={'result','profile_removed','installed_bytes_match','installed_files','stages'}
            or value['result']!='PASS' or value['profile_removed'] is not True or value['installed_bytes_match'] is not True
            or type(value['installed_files']) is not int or not 1<=value['installed_files']<=1000
            or not isinstance(value['stages'],list) or len(value['stages'])!=2):raise ValueError('note_download/ui')
    for stage,mode in zip(value['stages'],('live','reopen')):validate(stage,mode,count,1,download=True)
    return public_report(value)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--kind',choices=['thoughts','highlights'],default='thoughts');parser.add_argument('--native-ui-command',nargs=argparse.REMAINDER);args=parser.parse_args(argv)
    if args.native_ui_command and not args.saved_session:parser.error('native UI requires --saved-session')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),kind=args.kind,account_data_posts=0,authentication_posts=0,private_files=False)
    saved=credentials=notes=web=payload=None
    try:
        if args.saved_session:
            store=SessionStore();saved=store.load();credentials=NativeSessionStore().load(saved['vid'])
            notes=(TargetThoughtsProbe if args.kind=='thoughts' else TargetMarksProbe)();report['notes_preflight']=notes.prepare(credentials)
            model=notes.samples[0]['expected'] if args.kind=='thoughts' else notes.model
            uid,rows=selection(model,args.kind);report.update(selected_quotes=len(rows),selected_chapters=1,total_records=len(model['reviews' if args.kind=='thoughts' else 'updated']))
            web=WebSourceProbe();web.vid=saved['vid'];web.book_id=notes.identity
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account();baseline=position(web.request('progress_before',BASE+'/web/book/getProgress?bookId='+notes.identity),notes.identity)
            before,first=inspect(web,notes.identity,uid);after,sample=inspect(web,notes.identity,uid,{k:before[k] for k in FIELDS})
            if before!=after:raise ValueError('note_download/source_changed')
            targets=[(thought_target if args.kind=='thoughts' else mark_target)(sample['raw'],notes.identity,uid,row) for row in rows]
            report['source_read_twice']=True
            ui_failed=False
            if args.native_ui_command:
                payload=dict(book_id=notes.identity,owner=saved['vid'],cookies=current_cookies(web,saved['vid']),download_missing=True,
                             model=model,chapters=[dict(chapter_uid=uid,raw=sample['raw'],rows=rows,targets=targets)])
                if args.kind=='thoughts':payload['variant']='thoughts'
                raw=json.dumps(payload,ensure_ascii=False).encode()
                if len(raw)>12*1024*1024:raise ValueError('note_download/ui')
                child=subprocess.run(args.native_ui_command,input=raw,capture_output=True,timeout=600)
                if len(child.stdout)>512*1024 or child.stdout.count(DOWNLOAD_FRAME)!=1:raise ValueError('note_download/ui')
                result=json.loads(child.stdout.split(DOWNLOAD_FRAME)[1])
                if not isinstance(result,dict) or set(result)!={'report','cookies'}:raise ValueError('note_download/ui')
                report['native_ui']=public_report(result['report'])
                cookies=validate_cookies(result['cookies'],saved['vid']);web.cookies.clear()
                for key,value in cookies.items():web.set_cookie(key,value)
                web.verify_account()
                try:report['native_ui']=validate_ui(result['report'],len(rows))
                except ValueError:ui_failed=True
                ui_failed=ui_failed or child.returncode!=0
            snapshot_after(notes,credentials,args.kind,model)
            final=position(web.request('progress_after',BASE+'/web/book/getProgress?bookId='+notes.identity),notes.identity)
            if final!=baseline:raise ValueError('note_download/position_changed')
            if ui_failed:
                report.update(original_notes_unchanged=True,cloud_position_unchanged=True)
                raise ValueError('note_download/ui')
            report.update(result='NOTE_DOWNLOAD_VERIFIED' if args.native_ui_command else 'NOTE_DOWNLOAD_READY',original_notes_unchanged=True,cloud_position_unchanged=True)
            first.clear();sample.clear()
    except Exception as error:
        allowed={'note_download/'+key for key in ('no_quote','notes_changed','position_changed','source_changed','ui')}
        report.update(result='UNVERIFIED',reason=str(error) if str(error) in allowed else 'note_download/unverified')
    finally:
        if web:
            try:web.verify_account();report['rotation_saved']=save_refreshed_web_session(store,saved,web)
            except Exception:report.update(result='UNVERIFIED',reason='note_download/session_check')
            report['web_stages']=[{k:r[k] for k in ('stage','status','api_code') if k in r} for r in web.report['stages']];web.close()
        if notes:report['native_stages']=[{k:r[k] for k in ('stage','status','error_code') if k in r} for r in notes.report['stages']]
        for value in (saved,credentials,payload):
            if value:value.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
