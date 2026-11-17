#!/usr/bin/env python3
"""Read-only CB_ book-search feasibility; offline unless explicitly enabled."""
import argparse
import json
import re
import resource
import subprocess
from urllib.parse import parse_qs, urlencode, urlsplit

from fetch_weread_epub import decode_content_shards,make_content_params
from secure_weread_session import SessionStore
from verify_cb_progress import cb_id
from verify_cb_reading import CbReadingProbe, baseline_position, readable_chapters
from verify_source_coordinates import FilteredSource
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE, PreflightError, WebSourceProbe, versions
from verify_owner_book_search_ui import invoke


class SearchProbe(CbReadingProbe):
    """Permit one exact search and independent readbacks per selected book."""
    search_url=None
    keyword=None
    search_cursor=None

    def guard(self,stage,url,body):
        searches={'search_long','search_short','search_latin','ui_search_1','ui_search_2','ui_search_3','ui_search_4'}
        if stage in searches | {'search_progress_before','search_progress_after','search_catalog_before','search_catalog_after',
                                'ui_progress_before','ui_progress_after','ui_catalog_before','ui_catalog_after',
                                'ui_e_0','ui_e_1','ui_e_3','shelf_after'}:
            if not self.authenticated:raise ValueError('search_scope')
            if stage!='shelf_after' and (not cb_id(self.book_id) or self.book_id not in self.allowed):
                raise ValueError('search_scope')
            if stage in searches:
                parsed=urlsplit(url);query=parse_qs(parsed.query,keep_blank_values=True)
                cursor=self.search_cursor or {'chapter':self.chapter,'start':0,'finish':0}
                expected={'bookId':[self.book_id],'chapterUid':[cursor['chapter']],'keyword':[self.keyword],
                    'posBegin':[str(cursor['start'])],'posEnd':[str(cursor['finish'])],'mode':['scrollDown'],'count':['50']}
                if (body is not None or url!=self.search_url or parsed.scheme!='https' or parsed.netloc!='weread.qq.com'
                        or parsed.path!='/web/book/search_v2' or parsed.fragment or query!=expected
                        or not isinstance(self.keyword,str) or not 1<=len(self.keyword.encode())<=160
                        or any(ord(c)<32 or ord(c)==127 for c in self.keyword)):
                    raise ValueError('search_scope')
            elif stage in {'ui_e_0','ui_e_1','ui_e_3'}:
                if not isinstance(self.psvts,str) or not self.psvts or not isinstance(body,dict) or body.get('ps')!=self.psvts:
                    raise ValueError('search_scope')
                WebSourceProbe.guard(self,stage.removeprefix('ui_'),url,body)
            else:
                alias={'search_progress_before':'progress_before','search_progress_after':'progress_after',
                    'search_catalog_before':'catalog_before','search_catalog_after':'catalog_after',
                    'ui_progress_before':'progress_before','ui_progress_after':'progress_after',
                    'ui_catalog_before':'catalog_before','ui_catalog_after':'catalog_after','shelf_after':'shelf'}[stage]
                WebSourceProbe.guard(self,alias,url,body)
            key=(self.book_id if stage!='shelf_after' else '',stage)
            if self.used.get(key,0):raise ValueError('search_repeated')
            self.used[key]=1
            return
        return super().guard(stage,url,body)


def query_text(raw,widths=(12,8,4),alphabet='chinese'):
    model=FilteredSource(raw,allow_multiple_bodies=True)
    text=''.join(model.characters)
    for width in widths:
        for index in range(min(max(len(text)-width+1,0),20000)):
            candidate=text[index:index+width]
            pattern=('[\u4e00-\u9fff]' if alphabet=='chinese' else '[A-Za-z]')+'{%d}'%width
            if re.fullmatch(pattern,candidate) and text.count(candidate)==1:
                return candidate,(model.starts[index],model.ends[index+width-1])
    return None,None


def native_projection(sample,keyword,position,container,runtime,source):
    payload={'book':'900001','chapter':sample['chapter_uid'],'keyword':keyword,'raw':sample['source'],
        'hits':[{'start':position[0],'finish':position[1],'nonstandard':position[1]-position[0]!=len(keyword)}]}
    raw=json.dumps(payload,ensure_ascii=False,separators=(',',':')).encode()
    if len(raw)>8*1024*1024:raise ValueError('native_limit')
    command=['docker','exec','-i','-w',runtime,container,'sh','-c','ulimit -c 0; exec "$@"','sh',
        'xvfb-run','-a','./luajit',source+'/spec/koreader/book_search_target_probe.lua',source]
    result=subprocess.run(command,input=raw,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=90)
    marker=b'\nWEREAD_BOOK_SEARCH_TARGET='
    if result.returncode or result.stdout.count(marker)!=1 or len(result.stdout)>65536:raise ValueError('native_projection')
    value=json.loads(result.stdout.split(marker,1)[1].splitlines()[0])
    if not isinstance(value,dict) or value.get('result')!='PASS' or value.get('total')!=1:raise ValueError('native_projection')
    return value.get('verified')==1 and value.get('verified_offset_matches')==1


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--native-ui',action='store_true')
    parser.add_argument('--container',default='weread-validation')
    parser.add_argument('--runtime',default='/validation/runtime/lib/koreader')
    parser.add_argument('--source',default='/source')
    parser.add_argument('--candidate',default='/validation/cb-search-600-v3/candidate.zip')
    args=parser.parse_args(argv)
    if (not re.fullmatch('[A-Za-z0-9_.-]{1,128}',args.container)
            or any(not p.startswith('/') or '\x00' in p for p in (args.runtime,args.source,args.candidate))):parser.error('invalid isolated runtime')
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    report={'result':'OFFLINE_ONLY','account_data_posts':0,'authentication_posts':0,'search_gets':0}
    if not args.saved_session:
        print(json.dumps(report));return 0
    report['result']='UNVERIFIED';web=SearchProbe();saved=None;phase='session'
    try:
        store=SessionStore();saved=store.load();web.vid=saved['vid']
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();samples=web.prepare()
        observations=[];native_sample=None;phase='search'
        for sample in samples:
            web.book_id=sample['book_id'];web.chapter=sample['chapter_uid']
            position_url=BASE+'/web/book/getProgress?'+urlencode({'bookId':web.book_id})
            before=baseline_position(web.request('search_progress_before',position_url),web.book_id)
            first,chapters=readable_chapters(web.request('search_catalog_before',BASE+'/web/book/chapterInfos',{'bookIds':[web.book_id]}),web.book_id)
            if before!=sample['baseline'] or chapters!=sample['chapters']:raise ValueError('baseline_changed')
            observation={'source_format':sample['source_format'],'queries':[]}
            queries=[]
            if sample['source_format']=='web_xhtml':
                for label,widths,alphabet in (('search_long',(12,8,4),'chinese'),('search_short',(4,),'chinese')):
                    keyword,expected=query_text(sample['source'],widths,alphabet)
                    if keyword and all(q[1]!=keyword for q in queries):queries.append((label,keyword,expected))
                if not queries:
                    keyword,expected=query_text(sample['source'],(8,5),'latin')
                    if keyword:queries.append(('search_latin',keyword,expected))
            for label,keyword,expected in queries:
                web.keyword=keyword;web.search_cursor=None
                web.search_url=BASE+'/web/book/search_v2?'+urlencode({'bookId':web.book_id,'chapterUid':web.chapter,
                    'keyword':keyword,'posBegin':0,'posEnd':0,'mode':'scrollDown','count':50})
                report['search_gets']+=1
                found={'kind':label.removeprefix('search_'),'target_found':False,'target_source_matches':False,
                    'all_result_chapters_known':False,'native_projection_verified':False}
                try:
                    response=web.request(label,web.search_url)
                    rows=response.get('results',[]);more=response.get('scrollDownHasMore')
                    if not isinstance(rows,list) or len(rows)>200 or type(more) is not int or more not in (0,1):
                        raise ValueError('search_response')
                    ids={str(c['chapterUid']) for c in chapters};matches=[];known=True
                    for row in rows:
                        if not isinstance(row,dict) or not isinstance(row.get('matchWords'),list):raise ValueError('search_response')
                        known=known and str(row.get('chapterUid')) in ids
                        for word in row['matchWords']:
                            if not isinstance(word,dict):raise ValueError('search_response')
                            if str(row.get('chapterUid'))==web.chapter and word.get('word')==keyword:
                                matches.append((word.get('posBegin'),word.get('posEnd')))
                    found.update(response_valid=True,rows=len(rows),more=more==1,
                        target_found=bool(matches),target_source_matches=expected in matches,all_result_chapters_known=known)
                    if expected in matches:
                        found['native_projection_verified']=native_projection(sample,keyword,expected,args.container,args.runtime,args.source)
                        if found['native_projection_verified'] and native_sample is None:native_sample=(sample,keyword,expected)
                except PreflightError:
                    stage=web.report['stages'][-1]
                    found.update(response_valid=False,http_status=stage.get('status',0),api_error=stage.get('api_code') is not None)
                observation['queries'].append(found)
            after=baseline_position(web.request('search_progress_after',position_url),web.book_id)
            later,later_chapters=readable_chapters(web.request('search_catalog_after',BASE+'/web/book/chapterInfos',{'bookIds':[web.book_id]}),web.book_id)
            if before!=after or chapters!=later_chapters or versions(first)!=versions(later):raise ValueError('baseline_changed')
            observation.update(position_unchanged=True,catalog_unchanged=True)
            observations.append(observation)
        native_results=[]
        if args.native_ui:
            phase='native_ui'
            if not native_sample:raise ValueError('ui_no_sample')
            sample,keyword,expected=native_sample;web.book_id=sample['book_id'];web.chapter=sample['chapter_uid'];web.keyword=keyword
            web.psvts=sample['context']['psvts']
            position_url=BASE+'/web/book/getProgress?'+urlencode({'bookId':web.book_id})
            before=baseline_position(web.request('ui_progress_before',position_url),web.book_id)
            first,chapters=readable_chapters(web.request('ui_catalog_before',BASE+'/web/book/chapterInfos',{'bookIds':[web.book_id]}),web.book_id)
            if before!=sample['baseline'] or chapters!=sample['chapters']:raise ValueError('baseline_changed')
            ids=[str(row['chapterUid']) for row in chapters]
            if len(ids)!=len(set(ids)) or web.chapter not in ids:raise ValueError('ui_catalog')
            cursor={'chapter':ids[0],'start':0,'finish':0};allowed=[];seen=set();found=False
            for index in range(1,5):
                allowed.append(dict(cursor));web.search_cursor=dict(cursor)
                web.search_url=BASE+'/web/book/search_v2?'+urlencode({'bookId':web.book_id,'chapterUid':cursor['chapter'],
                    'keyword':keyword,'posBegin':cursor['start'],'posEnd':cursor['finish'],'mode':'scrollDown','count':50})
                report['search_gets']+=1;page=web.request('ui_search_'+str(index),web.search_url)
                rows=page.get('results',[]);more=page.get('scrollDownHasMore')
                if not isinstance(rows,list) or len(rows)>200 or type(more) is not int or more not in (0,1):raise ValueError('ui_page')
                for row in rows:
                    if not isinstance(row,dict) or str(row.get('chapterUid')) not in ids or not isinstance(row.get('matchWords'),list):raise ValueError('ui_page')
                    for word in row['matchWords']:
                        if (isinstance(word,dict) and str(row['chapterUid'])==web.chapter and word.get('word')==keyword
                                and (word.get('posBegin'),word.get('posEnd'))==expected):found=True
                if found:break
                if more==0 or not rows:raise ValueError('ui_no_target')
                last=rows[-1];cursor={'chapter':str(last.get('chapterUid')),'start':last.get('posBegin'),'finish':last.get('posEnd')}
                stamp=(cursor['chapter'],cursor['start'],cursor['finish'])
                if (cursor['chapter'] not in ids or any(type(cursor[k]) is not int or cursor[k]<0 for k in ('start','finish'))
                        or stamp in seen):raise ValueError('ui_cursor')
                seen.add(stamp)
            if not found:raise ValueError('ui_no_target')
            safe=[]
            for index,row in enumerate(chapters):
                words=row.get('wordCount');words=words if type(words) is int and 0<words<=10000000 else 1
                item={'chapterUid':str(row['chapterUid']),'title':'章节 '+str(index+1),'wordCount':words}
                idx=row.get('chapterIdx')
                if type(idx) is int and 0<=idx<=1000000:item['chapterIdx']=idx
                safe.append(item)
            cookies={c.name:c.value for c in web.cookies if c.name in {'wr_vid','wr_skey','wr_rt','wr_ql','wr_pf'}}
            payload=dict(owner=web.vid,cookies=cookies,book=web.book_id,chapter=web.chapter,chapters=safe,
                source=sample['source'],keyword=keyword,start=expected[0],finish=expected[1],allowed=allowed)
            for missing in (False,True):
                if missing:
                    other=next((uid for uid in ids if uid!=web.chapter),None)
                    if not other:raise ValueError('ui_no_other_chapter')
                    payload.update(download_missing=True,local_chapter=other)
                for width,height,dpi in ((600,800,167),(1264,1680,300)):
                    invoke(payload,args.container,args.runtime,args.source,args.candidate,width,height,dpi)
                native_results.append({'missing_chapter':missing,'screens':2,'result':'PASS'})
            after=baseline_position(web.request('ui_progress_after',position_url),web.book_id)
            later,later_chapters=readable_chapters(web.request('ui_catalog_after',BASE+'/web/book/chapterInfos',{'bookIds':[web.book_id]}),web.book_id)
            params=make_content_params(web.book_id,web.chapter,web.psvts,sc=1)
            reread=decode_content_shards(*(web.request('ui_'+kind,BASE+'/web/book/chapter/'+kind,params,as_json=False)
                for kind in ('e_0','e_1','e_3')))
            if before!=after or chapters!=later_chapters or versions(first)!=versions(later) or reread!=sample['source']:
                raise ValueError('baseline_changed')
            for entry in native_results:entry.update(position_unchanged=True,catalog_unchanged=True,source_unchanged=True)
        phase='readback'
        shelf=web.request('shelf_after',BASE+'/web/shelf/sync')
        if [str(row['bookId']) for row in shelf['books']]!=web.shelf_ids:raise ValueError('baseline_changed')
        web.verify_account();save_refreshed_web_session(store,saved,web)
        report.update(result='CB_SEARCH_READ_CHECKED',books=len(samples),observations=observations,shelf_unchanged=True,
            native_ui=native_results)
    except Exception as exc:
        report['phase']=phase
        if str(exc) in {'baseline_changed','search_scope','search_repeated','http_rejected','api_rejected'}:report['reason']=str(exc)
    finally:
        web.close()
        if saved:saved.clear()
    print(json.dumps(report,ensure_ascii=False));return int(report['result']!='CB_SEARCH_READ_CHECKED')


if __name__=='__main__':raise SystemExit(main())
