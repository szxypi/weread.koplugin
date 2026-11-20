#!/usr/bin/env python3
"""Read-only owner search and native UI acceptance; offline by default."""
import argparse
import json
import math
import re
import resource
import subprocess
from urllib.parse import urlencode

from fetch_weread_epub import decode_content_shards,make_content_params,normalize_chapter_infos,read_reader_state,reader_url_for
from secure_weread_session import SessionStore
from verify_cloud_book_search import Probe
from verify_source_coordinates import FilteredSource
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE,position,versions


def readable_catalog(chapters):
    selected=[]
    for row in chapters:
        words=row.get('wordCount',0)
        if isinstance(words,bool) or not isinstance(words,(str,int,float)):continue
        try:number=float(words)
        except ValueError:continue
        if math.isfinite(number) and number>0 and str(row.get('title') or '')!='封面':selected.append(row)
    return selected


def invoke(payload,container,runtime,source,candidate,width,height,dpi):
    command=['docker','exec','-i','-w',runtime,container,'sh','-c','ulimit -c 0; exec "$@"','sh',
        'xvfb-run','-a','python3',source+'/scripts/run_owner_book_search_ui.py','--koreader',runtime,
        '--candidate',candidate,'--width',str(width),'--height',str(height),'--dpi',str(dpi)]
    raw=json.dumps(payload,ensure_ascii=False,separators=(',',':')).encode()
    if len(raw)>8*1024*1024:raise ValueError('owner_ui/input')
    child=subprocess.run(command,input=raw,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=240)
    if len(child.stdout)>65536:raise ValueError('owner_ui/runner')
    value=json.loads(child.stdout)
    if child.returncode:
        failure=value.get('failure_phase') if isinstance(value,dict) else None
        detail=value.get('navigation_diagnostic') if isinstance(value,dict) else None
        failure_detail=value.get('failure_detail') if isinstance(value,dict) else None
        if failure=='search' and failure_detail in ('unknown','blocked','blocked_catalog','blocked_policy','blocked_search','blocked_other','http_failed','no_catalog','no_search','after_search'):
            raise ValueError('owner_ui/search_'+failure_detail)
        if failure=='navigate' and detail in ('unknown','confirm','working','ready_target','ready_no_target','inactive','bind_failed','source_opened','other','locate_failed','position_unavailable','save_failed'):
            raise ValueError('owner_ui/navigation_'+detail)
        if failure in ('decode','reader','search','navigate'):raise ValueError('owner_ui/native_'+failure)
        raise ValueError('owner_ui/runner')
    if (not isinstance(value,dict) or set(value)!={'result','profile_removed','installed_bytes_match','account_data_posts','authentication_posts','ui'}
            or value['result']!='PASS' or value['profile_removed'] is not True or value['installed_bytes_match'] is not True
            or type(value['account_data_posts']) is not int or value['account_data_posts']!=0
            or type(value['authentication_posts']) is not int or value['authentication_posts']!=0):
        raise ValueError('owner_ui/report')
    ui=value['ui'];flags=('native_menu','search_result_verified','source_navigation','workers_reaped')
    missing=payload.get('download_missing') is True
    extra={'download_confirmed','cancel_without_download','downloaded_source_verified','credential_audit',
        'download_gets','catalog_posts','content_posts'} if missing else set()
    catalog_missing=payload.get('catalog_missing') is True
    if catalog_missing:extra|={'catalog_restored','catalog_gets','catalog_read_posts','credential_audit'}
    if (not isinstance(ui,dict) or set(ui)!={'result',*flags,'account_gets','search_gets','denied_requests',*extra}
            or ui['result']!='PASS' or any(ui[k] is not True for k in flags)
            or type(ui['account_gets']) is not int or not 1<=ui['account_gets']<=len(payload['allowed'])
            or type(ui['search_gets']) is not int or ui['search_gets']!=ui['account_gets']
            or type(ui['denied_requests']) is not int or ui['denied_requests']!=0):
        raise ValueError('owner_ui/report')
    if missing and (any(ui[k] is not True for k in ('download_confirmed','cancel_without_download',
            'downloaded_source_verified','credential_audit'))
            or any(type(ui[k]) is not int or ui[k]<1 for k in ('download_gets','catalog_posts','content_posts'))):
        raise ValueError('owner_ui/download_report')
    if catalog_missing and (ui['catalog_restored'] is not True or ui['credential_audit'] is not True
            or any(type(ui[k]) is not int or ui[k]<1 for k in ('catalog_gets','catalog_read_posts'))):
        raise ValueError('owner_ui/catalog_report')
    return value


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--missing-chapter',action='store_true',help='also validate confirmed read-only download')
    parser.add_argument('--missing-catalog',action='store_true',help='validate read-only catalog restoration')
    parser.add_argument('--container',default='weread-validation');parser.add_argument('--runtime',default='/validation/runtime/lib/koreader')
    parser.add_argument('--source',default='/source');parser.add_argument('--candidate',default='/validation/book-search-cached600-v5/candidate.zip')
    args=parser.parse_args(argv)
    if args.missing_catalog and args.missing_chapter:parser.error('select one missing-cache scenario')
    if (not re.fullmatch('[A-Za-z0-9_.-]{1,128}',args.container)
            or any(not p.startswith('/') or '\x00' in p for p in (args.runtime,args.source,args.candidate))):parser.error('invalid isolated runtime')
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    report={'result':'OFFLINE_ONLY','account_data_posts':0,'authentication_posts':0,'screenshots':0}
    if not args.saved_session:
        print(json.dumps(report));return 0
    report['result']='UNVERIFIED';web=Probe();saved=None;phase='session'
    try:
        store=SessionStore();saved=store.load();web.vid=saved['vid']
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();book=web.select_shelf_book()
        progress_url=BASE+'/web/book/getProgress?'+urlencode({'bookId':book})
        before=position(web.request('progress_before',progress_url),book);web.chapter=before['chapter']
        state=read_reader_state(web.request('reader',reader_url_for(book,web.chapter),as_json=False))
        if state.book_id!=book or str(state.current_chapter.get('chapterUid'))!=web.chapter:raise ValueError('owner_ui/reader')
        first_record,chapters=normalize_chapter_infos(web.request('catalog_before',BASE+'/web/book/chapterInfos',{'bookIds':[book]}),book)
        if sum(str(row.get('chapterUid'))==web.chapter for row in chapters)!=1:raise ValueError('owner_ui/catalog')
        params=make_content_params(book,web.chapter,state.psvts,sc=1)
        original=decode_content_shards(*(web.request(k,BASE+'/web/book/chapter/'+k,params,as_json=False) for k in ('e_0','e_1','e_3')))
        model=FilteredSource(original);text=''.join(model.characters);keyword=None;index=None
        for i in range(min(len(text)-12,20000)):
            candidate=text[i:i+12]
            if re.fullmatch('[\u4e00-\u9fff]{12}',candidate) and text.count(candidate)==1:
                keyword,index=candidate,i;break
        if keyword is None:raise ValueError('owner_ui/keyword')
        start,finish=model.starts[index],model.ends[index+len(keyword)-1]
        search_chapters=readable_catalog(chapters) if args.missing_catalog else chapters
        ids=[str(row.get('chapterUid')) for row in search_chapters]
        if len(ids)!=len(set(ids)) or any(not re.fullmatch('[1-9][0-9]{0,19}',uid) for uid in ids):raise ValueError('owner_ui/catalog')
        if not ids or web.chapter not in ids:raise ValueError('owner_ui/catalog')
        cursor={'chapter':ids[0],'start':0,'finish':0};allowed=[];seen=set();found=False
        phase='preflight'
        for _i in range(4):
            allowed.append(dict(cursor))
            web.search_url=BASE+'/web/book/search_v2?'+urlencode({'bookId':book,'chapterUid':cursor['chapter'],'keyword':keyword,
                'posBegin':cursor['start'],'posEnd':cursor['finish'],'mode':'scrollDown','count':50})
            page=web.request('search_probe',web.search_url);rows=page.get('results',[]);more=page.get('scrollDownHasMore')
            if not isinstance(rows,list) or len(rows)>200 or type(more) is not int or more not in (0,1):raise ValueError('owner_ui/page')
            for row in rows:
                if not isinstance(row,dict) or str(row.get('chapterUid')) not in ids or not isinstance(row.get('matchWords'),list):raise ValueError('owner_ui/page')
                for word in row['matchWords']:
                    if (isinstance(word,dict) and str(row['chapterUid'])==web.chapter and word.get('word')==keyword
                            and word.get('posBegin')==start and word.get('posEnd')==finish):found=True
            if found:break
            if more==0 or not rows:raise ValueError('owner_ui/no_target')
            last=rows[-1];cursor={'chapter':str(last.get('chapterUid')),'start':last.get('posBegin'),'finish':last.get('posEnd')}
            stamp=(cursor['chapter'],cursor['start'],cursor['finish'])
            if (cursor['chapter'] not in ids or any(type(cursor[k]) is not int or cursor[k]<0 for k in ('start','finish'))
                    or stamp in seen):raise ValueError('owner_ui/cursor')
            seen.add(stamp)
        if not found:raise ValueError('owner_ui/no_target')
        safe_chapters=[]
        for i,row in enumerate(search_chapters):
            words=row.get('wordCount')
            if type(words) is not int or not 0<words<=10000000:words=1
            item={'chapterUid':str(row['chapterUid']),'title':'章节 '+str(i+1),'wordCount':words}
            idx=row.get('chapterIdx')
            if type(idx) is int and 0<=idx<=1000000:item['chapterIdx']=idx
            safe_chapters.append(item)
        cookies={c.name:c.value for c in web.cookies if c.name in {'wr_vid','wr_skey','wr_rt','wr_ql','wr_pf'}}
        payload=dict(owner=web.vid,cookies=cookies,book=book,chapter=web.chapter,chapters=safe_chapters,
            source=original,keyword=keyword,start=start,finish=finish,allowed=allowed)
        if args.missing_chapter:
            other=next((uid for uid in ids if uid!=web.chapter),None)
            if other is None:raise ValueError('owner_ui/no_other_chapter')
            payload.update(download_missing=True,local_chapter=other)
        if args.missing_catalog:payload['catalog_missing']=True
        phase='native_ui';stages=[]
        for width,height,dpi in ((600,800,167),(1264,1680,300)):
            stages.append(invoke(payload,args.container,args.runtime,args.source,args.candidate,width,height,dpi))
        phase='readback'
        later,later_chapters=normalize_chapter_infos(web.request('catalog_after',BASE+'/web/book/chapterInfos',{'bookIds':[book]}),book)
        after=position(web.request('progress_after',progress_url),book)
        reread=decode_content_shards(*(web.request(k,BASE+'/web/book/chapter/'+k,params,as_json=False) for k in ('e_0','e_1','e_3')))
        web.verify_account();save_refreshed_web_session(store,saved,web)
        if before!=after or chapters!=later_chapters or versions(first_record)!=versions(later) or original!=reread:
            raise ValueError('owner_ui/changed')
        report.update(result='OWNER_UI_READ_VERIFIED',stages=stages,position_unchanged=True,catalog_unchanged=True,source_unchanged=True)
    except Exception as exc:
        report['phase']=phase
        if str(exc) in ('owner_ui/native_decode','owner_ui/native_reader','owner_ui/native_search','owner_ui/native_navigate'):
            report['native_phase']=str(exc).removeprefix('owner_ui/native_')
        if str(exc) in tuple('owner_ui/navigation_'+v for v in ('unknown','confirm','working','ready_target','ready_no_target','inactive','bind_failed','source_opened','other','locate_failed','position_unavailable','save_failed')):
            report['native_phase']='navigate';report['navigation_diagnostic']=str(exc).removeprefix('owner_ui/navigation_')
        if str(exc) in tuple('owner_ui/search_'+v for v in ('unknown','blocked','blocked_catalog','blocked_policy','blocked_search','blocked_other','http_failed','no_catalog','no_search','after_search')):
            report['native_phase']='search';report['search_diagnostic']=str(exc).removeprefix('owner_ui/search_')
    finally:
        web.close()
        if saved:saved.clear()
    print(json.dumps(report,ensure_ascii=False));return int(report['result']!='OWNER_UI_READ_VERIFIED')


if __name__=='__main__':raise SystemExit(main())
