#!/usr/bin/env python3
"""Read-only Web/native position availability and private Python/Lua comparison."""
import argparse
from datetime import datetime,timezone
import json
import resource
import subprocess
from source_remote_position import outcome,public_report
from verify_reader_progress import project,find_node
from verify_web_source_progress import WebSourceProbe,BASE,identifier
from verify_eink_login import BASE as NATIVE
from verify_native_txt_position import Native
from secure_weread_session import SessionStore
from secure_native_session import NativeSessionStore
from fetch_weread_epub import normalize_chapter_infos
from shelf_flag_change_contract import state_hash
from verify_translation_preflight import save_refreshed_web_session

FRAME=b'\nWEREAD_SOURCE_REMOTE_RESULT='


def observation(raw,book):
    p=project(raw,book);node=find_node(raw,book)
    if any(k in node and (type(node[k]) is not int or not 0<=node[k]<=2**53-1) for k in ('readingTime','recordReadingTime','ttsTime')):raise ValueError('source_remote/counts')
    # Presence, not defaulted zero, is part of the independent comparison.
    return dict(position={k:p.get(k) for k in ('book_id','chapter_uid','chapter_idx','chapter_offset','raw_percent','summary')},
                fields={k:node[k] for k in ('chapterUid','chapterId','chapter_uid','chapterIdx','chapterIndex','chapter_idx',
                                          'chapterOffset','chapterPos','offset','chapter_offset','updateTime','updatedAt','update_time','summary','readingTime','recordReadingTime','ttsTime') if k in node})


def compare(raw,samples):
    if not isinstance(raw,bytes) or len(raw)>4*1024*1024 or raw.count(FRAME)!=1:raise ValueError('source_remote/frame')
    values=json.loads(raw.split(FRAME)[1])
    if not isinstance(values,list) or len(values)!=len(samples):raise ValueError('source_remote/frame')
    expected=[outcome(s['raw'],s['book_id'],s['chapters'],s['source']) for s in samples]
    if values!=expected:raise ValueError('source_remote/model')


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--saved-session',action='store_true')
    p.add_argument('--sample',type=int,choices=range(1,17),default=8);p.add_argument('--lua-command',nargs=argparse.REMAINDER);a=p.parse_args(argv)
    if a.lua_command is not None and (not a.lua_command or not a.saved_session):p.error('explicit saved session required')
    r=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,authentication_posts=0,
           private_responses_on_regular_disk=False,books_checked=0,observations_checked=0,no_chapter=0,located=0,incomplete=0,
           web_indices_missing=0,native_indices_missing=0,python_lua_matches=False,read_fields_stable=False,catalog_and_shelf_stable=False)
    web=grant=saved=None;natives=[];samples=[];private_literals=set()
    try:
        if a.saved_session:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0))
            from verify_native_thought_trial import other_pending
            if other_pending():raise ValueError('source_remote/pending')
            store=SessionStore();saved=store.load();grant=NativeSessionStore().load(saved['vid']);web=WebSourceProbe();web.vid=saved['vid']
            private_literals.update(str(v) for v in grant.values());private_literals.update(saved['cookies'].values());private_literals.add(web.vid)
            for k,v in saved['cookies'].items():web.set_cookie(k,v)
            web.verify_account();shelf=web.request('shelf',BASE+'/web/shelf/sync');shelf_hash=state_hash(shelf)
            ids=[]
            for row in sorted(shelf.get('books',[]),key=lambda v:0 if isinstance(v,dict) and v.get('format')=='txt' else 1):
                try:key=identifier(row.get('bookId'))
                except Exception:continue
                if key not in ids:ids.append(key)
            for key in ids[:a.sample]:
                web.book_id=key;private_literals.add(key)
                raw=web.request('selection_progress',BASE+'/web/book/getProgress?bookId='+key)
                record,chapters=normalize_chapter_infos(web.request('catalog_before',BASE+'/web/book/chapterInfos',dict(bookIds=[key])),key)
                api=Native(grant,key);natives.append(api)
                native=api.request('source_remote_before',NATIVE+'/book/getProgress?bookId='+key,credentials=grant)
                for source,value in (('web',raw),('native',native)):
                    private_literals.add(project(value,key).get('summary',''))
                    sample=dict(raw=value,book_id=key,chapters=chapters,source=source);result=outcome(value,key,chapters,source);samples.append(sample)
                    if result['ok']:r['located']+=1
                    elif result['reason']=='progress_no_chapter':r['no_chapter']+=1
                    elif result['reason']=='progress_source_incomplete':r['incomplete']+=1
                    else:raise ValueError('source_remote/unverified_response')
                    if not any(k in find_node(value,key) for k in ('chapterIdx','chapterIndex','chapter_idx')):r[source+'_indices_missing']+=1
                again=api.request('source_remote_after',NATIVE+'/book/getProgress?bookId='+key,credentials=grant)
                later=web.request('progress_after',BASE+'/web/book/getProgress?bookId='+key)
                record2,chapters2=normalize_chapter_infos(web.request('catalog_after',BASE+'/web/book/chapterInfos',dict(bookIds=[key])),key)
                if observation(raw,key)!=observation(later,key) or observation(native,key)!=observation(again,key):raise ValueError('source_remote/changed')
                if record!=record2 or chapters!=chapters2:raise ValueError('source_remote/catalog_changed')
                r['books_checked']+=1
            if not samples:raise ValueError('source_remote/no_samples')
            if a.lua_command:
                encoded=json.dumps(dict(samples=samples),ensure_ascii=False,separators=(',',':')).encode()
                if len(encoded)>4*1024*1024:raise ValueError('source_remote/input')
                child=subprocess.run(a.lua_command,input=encoded,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=60)
                if child.returncode:raise ValueError('source_remote/child')
                compare(child.stdout,samples);r['python_lua_matches']=True
            if state_hash(web.request('shelf',BASE+'/web/shelf/sync'))!=shelf_hash:raise ValueError('source_remote/shelf_changed')
            web.verify_account();save_refreshed_web_session(store,saved,web)
            if NativeSessionStore().load(saved['vid'])!=grant or other_pending():raise ValueError('source_remote/scope_changed')
            r.update(result='SOURCE_REMOTE_READONLY_VERIFIED',observations_checked=len(samples),read_fields_stable=True,catalog_and_shelf_stable=True)
    except (Exception,KeyboardInterrupt) as error:
        r['result']='UNVERIFIED'
        import re
        if isinstance(error,ValueError) and re.fullmatch('source_remote/[a-z_]+',str(error)):r['reason']=str(error)
    finally:
        if web:
            r['web_stages']=[{k:x[k] for k in ('stage','status','api_code') if k in x} for x in web.report['stages']];web.close()
        r['native_stages']=[{k:x[k] for k in ('stage','status','error_code') if k in x} for n in natives for x in n.report['stages']]
        samples.clear()
        for v in (saved,grant):
            if v:v.clear()
    r=public_report(r,private_literals)
    print(json.dumps(r,indent=2));return int(r['result']=='UNVERIFIED')


if __name__=='__main__':raise SystemExit(main())
