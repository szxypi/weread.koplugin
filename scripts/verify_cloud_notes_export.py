#!/usr/bin/env python3
"""Bounded read-only account comparison; private notes only use memory pipes."""
import argparse
import json
import re
import resource
import subprocess
import time
from urllib.parse import urlencode

from my_cloud_marks_model import project
from my_cloud_thoughts_model import complete
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from shelf_flag_change_contract import state_hash
from verify_eink_login import BASE, NativeProbe

FRAME=b'\nWEREAD_CLOUD_NOTES_EXPORT='
UI_FRAME=b'\nWEREAD_CLOUD_NOTES_UI='


def expected_rows(marks, thoughts):
    titles={row['chapterUid']:row['title'] for row in marks['chapters']}
    left=[]
    for row in marks['updated']:
        item={'kind':'highlight' if row.get('type')==1 else 'bookmark' if row.get('type')==0 else 'mark'}
        for source,target in (('markText','text'),('abstract','abstract'),('createTime','created_at'),
                              ('style','style'),('colorStyle','color_style')):
            if source in row:item[target]=row[source]
        if row.get('chapterUid') in titles:item['chapter']=titles[row['chapterUid']]
        left.append(item)
    right=[]
    for row in thoughts['reviews']:
        item={'content':row['content'],'visibility':'private' if row.get('isPrivate')==1 else
              'public' if row.get('isPrivate')==0 else 'unknown'}
        for source,target in (('abstract','abstract'),('createTime','created_at')):
            if source in row:item[target]=row[source]
        chapter=row['chapterName'] if 'chapterName' in row else titles.get(row.get('chapterUid'))
        if chapter is not None:item['chapter']=chapter
        right.append(item)
    return left,right


def quoted(value):
    value=value.replace('\r\n','\n').replace('\r','\n')
    value=value.replace('&','&amp;').replace('<','&lt;').replace('>','&gt;')
    value=re.sub(r'([\\`*_{}\[\]()#+.!|~\-])',r'\\\1',value)
    return '> '+value.replace('\n','\n> ')+'\n\n'


def compare(raw, marks, thoughts):
    if not isinstance(raw,bytes) or len(raw)>24*1024*1024 or raw.count(FRAME)!=1:raise ValueError('cloud_export/frame')
    value=json.loads(raw.split(FRAME,1)[1]);left,right=expected_rows(marks,thoughts)
    if (not isinstance(value,dict) or set(value)!={'result','count','json','markdown'} or value['result']!='PASS'
            or type(value['count']) is not int or value['count']!=len(left)+len(right) or not isinstance(value['markdown'],str)):
        raise ValueError('cloud_export/result')
    exported=value['json']
    if (not isinstance(exported,dict) or set(exported)!={'schema','source','book','snapshots','marks','thoughts'}
            or exported['schema']!=1 or exported['source']!='WeRead' or exported['marks']!=left or exported['thoughts']!=right
            or exported['snapshots']!={'marks':{'available':True,'fetched_at':marks['fetched_at']},
                                      'thoughts':{'available':True,'fetched_at':thoughts['fetched_at']}}
            or not isinstance(exported['book'],dict) or set(exported['book'])!={'title','author','exported_at'}
            or exported['book'].get('title')!='Synthetic export' or exported['book'].get('author')!=''
            or not isinstance(exported['book'].get('exported_at'),str)):
        raise ValueError('cloud_export/content')
    markdown=value['markdown']
    for row in left:
        for text in (row.get('text'),row.get('abstract') if row.get('abstract')!=row.get('text') else None):
            if text and quoted(text) not in markdown:raise ValueError('cloud_export/markdown')
    for row in right:
        for text in (row.get('abstract'),row.get('content')):
            if text and quoted(text) not in markdown:raise ValueError('cloud_export/markdown')
    return len(left),len(right)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--native-ui',action='store_true')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if bool(args.saved_session)!=bool(args.lua_command):parser.error('saved session and private command are required together')
    if args.native_ui and not args.saved_session:parser.error('native UI requires saved session and private command')
    report=dict(result='OFFLINE_ONLY',account_data_writes=0,authentication_posts=0,private_notes_saved=False)
    saved=grant=None
    try:
        if args.saved_session:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0))
            saved=SessionStore().load();grant=NativeSessionStore().load(saved['vid']);api=NativeProbe()
            shelf=api.request('shelf',BASE+'/shelf/sync',credentials=grant);baseline=state_hash(shelf)
            ids=[]
            for row in shelf.get('books',[]):
                key=str(row.get('bookId','')) if isinstance(row,dict) else ''
                if re.fullmatch(r'[1-9][0-9]{0,19}',key) and key not in ids:ids.append(key)
            now=int(time.time());selected=fallback=None
            for key in ids[:16]:
                raw_marks=api.request('marks',BASE+'/book/bookmarklist?'+urlencode(dict(bookId=key,synckey=0)),credentials=grant)
                marks=project(raw_marks,key,saved['vid'],now)
                if not marks['updated']:continue
                raw_thoughts=api.request('thoughts',BASE+'/review/list?'+urlencode(dict(bookId=key,listType=11,listMode=0,mine=1,synckey=0,count=20)),credentials=grant)
                try:thoughts=complete(raw_thoughts,key,saved['vid'],now)
                except ValueError:continue
                if thoughts['reviews']:
                    selected=(key,marks,thoughts,raw_marks);break
                if fallback is None:fallback=(key,marks,thoughts,raw_marks)
            selected=selected or fallback
            if not selected:raise ValueError('cloud_export/no_sample')
            key,marks,thoughts,raw_marks=selected
            if args.native_ui:
                payload=dict(owner_export=True,source=raw_marks,book_id=key,owner=saved['vid'],now=now,other_thoughts=thoughts,
                             credentials=dict(vid=saved['vid'],accessToken='offline-access',refreshToken='offline-refresh',deviceId='1'*32))
            else:
                payload=dict(book_id=key,book=dict(title='Synthetic export',author=''),now=now,marks=marks,thoughts=thoughts)
            child=subprocess.run(args.lua_command,input=json.dumps(payload,ensure_ascii=False,separators=(',',':')).encode(),
                                 stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=180 if args.native_ui else 60)
            if args.native_ui and child.stdout.count(UI_FRAME)==1 and len(child.stdout)<=24*1024*1024:
                try:
                    partial=json.loads(child.stdout.split(UI_FRAME,1)[1].split(FRAME,1)[0])
                    stages=partial.get('stages',[]) if isinstance(partial,dict) else []
                    report['ui_diagnostics']=[{key:row[key] for key in ('failed_line','requests','forbidden')
                        if type(row.get(key)) is int and 0<=row[key]<=100000} for row in stages[:2] if isinstance(row,dict)]
                except (ValueError,TypeError):pass
            if child.returncode:raise ValueError('cloud_export/runtime')
            if args.native_ui:
                if child.stdout.count(UI_FRAME)!=1 or child.stdout.count(FRAME)!=1:raise ValueError('cloud_export/ui_frame')
                ui=json.loads(child.stdout.split(UI_FRAME,1)[1].split(FRAME,1)[0])
                if (set(ui)!={'result','profile_removed','stages','offline_network_guard','independent_reopen','temporary_files_removed'}
                        or ui['result']!='PASS' or any(ui[key] is not True for key in ('profile_removed','offline_network_guard',
                            'independent_reopen','temporary_files_removed')) or not isinstance(ui['stages'],list) or len(ui['stages'])!=2):
                    raise ValueError('cloud_export/ui')
                for stage in ui['stages']:
                    if (stage!={'result':'PASS','phase':'complete','failed_line':0,'requests':0,'forbidden':0}
                            or any(type(stage[key]) is not int for key in ('failed_line','requests','forbidden'))):
                        raise ValueError('cloud_export/ui_stage')
                report['native_ui']=ui
                report['private_notes_only_on_tmpfs']=True
            left,right=compare(child.stdout,marks,thoughts)
            again=project(api.request('marks_after',BASE+'/book/bookmarklist?'+urlencode(dict(bookId=key,synckey=0)),credentials=grant),key,saved['vid'],now)
            later=complete(api.request('thoughts_after',BASE+'/review/list?'+urlencode(dict(bookId=key,listType=11,listMode=0,mine=1,synckey=0,count=20)),credentials=grant),key,saved['vid'],now)
            if again!=marks or later!=thoughts or state_hash(api.request('shelf_after',BASE+'/shelf/sync',credentials=grant))!=baseline:
                raise ValueError('cloud_export/changed')
            report.update(result='REAL_CLOUD_EXPORT_READONLY_VERIFIED',marks=left,thoughts=right,
                          json_exact=True,markdown_quotes_exact=True,cloud_snapshots_unchanged=True)
    except (Exception,KeyboardInterrupt):
        report['result']='UNVERIFIED'
    finally:
        if saved:saved.clear()
        if grant:grant.clear()
    print(json.dumps(report))
    return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
