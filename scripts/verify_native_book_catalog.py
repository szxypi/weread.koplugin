#!/usr/bin/env python3
"""Compare native reading catalog projections; saved session only when explicit."""
import argparse
import json
import resource
import subprocess
from urllib.parse import urlencode

from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from shelf_flag_change_contract import state_hash
from verify_eink_login import BASE
from verify_native_chapter_package import ChapterProbe
from verify_native_discovery import identity
from verify_translation_preflight import catalog, catalog_body

FRAME=b'\nWEREAD_NATIVE_BOOK_CATALOG='


def integer(value, maximum):
    if isinstance(value,str) and value.isascii() and value.isdigit() and len(value)<=16 and (value=='0' or not value.startswith('0')):
        value=int(value)
    if type(value) is not int or not 0<=value<=maximum:
        raise ValueError('invalid_display_field')
    return value


def expected(raw, book_id, info):
    model=catalog(raw,book_id,info)
    records=[row for row in raw['data'] if identity(row.get('bookId'))==book_id]
    if len(records)!=1:raise ValueError('identity')
    result=[]
    for source,item in zip(records[0]['updated'],model['chapters']):
        if item['uid']==0:continue
        title=source.get('title') if source.get('title') is not None else ''
        if not isinstance(title,str) or len(title.encode())>2048:raise ValueError('title')
        a=integer(source['chapterIdx'],1000000) if 'chapterIdx' in source else None
        b=integer(source['chapterIndex'],1000000) if 'chapterIndex' in source else None
        if a is not None and b is not None and a!=b:raise ValueError('index')
        level=integer(source['level'],100) if 'level' in source else 1
        words=item.get('wordCount',0)
        if words>100000000:raise ValueError('words')
        row=dict(chapterUid=str(item['uid']),title=title,level=level,wordCount=words,
                 downloadable=item['free_or_owned'])
        if a is not None or b is not None:row['chapterIdx']=a if a is not None else b
        result.append(row)
    if not result:raise ValueError('empty')
    return dict(version=model['version'],chapters=result)


def compare(raw,book_id,info,command,runner=subprocess.run):
    model=expected(raw,book_id,info)
    data=json.dumps(dict(raw=raw,book_id=book_id,info=info),ensure_ascii=False,separators=(',',':')).encode()
    if len(data)>4*1024*1024:raise ValueError('input_limit')
    child=runner(command,input=data,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=60)
    if child.returncode or len(child.stdout)>4*1024*1024 or child.stdout.count(FRAME)!=1:raise ValueError('child')
    actual=json.loads(child.stdout.split(FRAME,1)[1].splitlines()[0])
    if actual!=model:raise ValueError('mismatch')
    return len(model['chapters']),sum(row['downloadable'] for row in model['chapters'])


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if bool(args.saved_session)!=bool(args.lua_command):parser.error('saved session and private Lua command are required together')
    report=dict(result='OFFLINE_ONLY',account_data_writes=0,authentication_posts=0,private_data_saved=False)
    saved=credentials=api=None
    try:
        if args.saved_session:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0))
            saved=SessionStore().load();credentials=NativeSessionStore().load(saved['vid']);api=ChapterProbe()
            shelf=api.request('shelf',BASE+'/shelf/sync',credentials=credentials);before=state_hash(shelf)
            keys=[]
            for row in shelf.get('books',[]):
                key=identity(row.get('bookId')) if isinstance(row,dict) else None
                if key and key not in keys:keys.append(key)
                if len(keys)==3:break
            if len(keys)!=3:raise ValueError('insufficient_samples')
            api.allowed=set(keys);sizes=[]
            for key in keys:
                info=api.request('book',BASE+'/book/info?'+urlencode({'bookId':key}),credentials=credentials)
                raw=api.request('catalog',BASE+'/book/chapterInfos',catalog_body(key),credentials=credentials)
                chapters,readable=compare(raw,key,info,args.lua_command)
                sizes.append(dict(chapters=chapters,explicitly_free_or_owned=readable))
            if state_hash(api.request('shelf',BASE+'/shelf/sync',credentials=credentials))!=before:
                raise ValueError('shelf_changed')
            report.update(result='NATIVE_BOOK_CATALOG_READONLY_VERIFIED',samples=sizes,shelf_unchanged=True)
    except (Exception,KeyboardInterrupt):report['result']='UNVERIFIED'
    finally:
        if saved:saved.clear()
        if credentials:credentials.clear()
    print(json.dumps(report))
    return int(report['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
