#!/usr/bin/env python3
"""Compare bounded CB_ search queries from within retained source segments."""
import argparse
import json
import re
import resource
from urllib.parse import urlencode

from fetch_weread_epub import decode_content_shards,make_content_params
from secure_weread_session import SessionStore
from verify_cb_book_search import SearchProbe
from verify_cb_progress import cb_id
from verify_cb_reading import baseline_position,readable_chapters
from verify_source_coordinates import FilteredSource
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE,PreflightError,versions
from verify_owner_book_search_ui import invoke


class BoundaryProbe(SearchProbe):
    first_chapter=None
    def guard(self,stage,url,body):
        if stage in {'segment_1_current','segment_1_first','segment_2_current','segment_2_first'}:
            # Reuse the exact same query validator, while retaining a distinct
            # one-shot budget for each segment and starting chapter.
            if not cb_id(self.book_id) or self.book_id not in self.allowed:raise ValueError('search_scope')
            expected=self.chapter if stage.endswith('_current') else self.first_chapter
            if not expected or not isinstance(self.search_cursor,dict) or self.search_cursor.get('chapter')!=expected:
                raise ValueError('search_scope')
            synthetic=(self.book_id,'search_long');previous=self.used.pop(synthetic,None)
            try:super().guard('search_long',url,body)
            finally:
                self.used.pop(synthetic,None)
                if previous is not None:self.used[synthetic]=previous
            key=(self.book_id,stage)
            if self.used.get(key,0):raise ValueError('search_repeated')
            self.used[key]=1
            return
        return super().guard(stage,url,body)


def segment_queries(raw):
    model=FilteredSource(raw,allow_multiple_bodies=True)
    visible=''.join(model.characters);found=[]
    for width in (8,4):
        patterns=(r'[\u4e00-\u9fff]{%d}'%width,r'[A-Za-z]{%d}'%width)
        chosen=None;checked=0
        for _base,segment in model.segments:
            for pattern in patterns:
                for match in re.finditer(pattern,segment):
                    checked+=1
                    if checked>128:break
                    word=match.group()
                    if visible.count(word)!=1 or any(word==old[0] for old in found):continue
                    index=visible.find(word)
                    if index<0:continue
                    chosen=(word,(model.starts[index],model.ends[index+len(word)-1]))
                    break
                if chosen or checked>128:break
            if chosen or checked>128:break
        if chosen:found.append(chosen)
    return found


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--native-ui',action='store_true');parser.add_argument('--container',default='weread-validation')
    parser.add_argument('--runtime',default='/validation/runtime/lib/koreader');parser.add_argument('--source',default='/source')
    parser.add_argument('--candidate',default='/validation/cb-fallback-600-v5/candidate.zip')
    args=parser.parse_args(argv);resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    if (not re.fullmatch('[A-Za-z0-9_.-]{1,128}',args.container)
            or any(not p.startswith('/') or '\x00' in p for p in (args.runtime,args.source,args.candidate))):parser.error('invalid isolated runtime')
    report={'result':'OFFLINE_ONLY','account_data_posts':0,'authentication_posts':0,'search_gets':0}
    if not args.saved_session:
        print(json.dumps(report));return 0
    report['result']='UNVERIFIED';web=BoundaryProbe();saved=None;phase='session'
    try:
        store=SessionStore();saved=store.load();web.vid=saved['vid']
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();samples=web.prepare();observations=[];phase='search';restricted=False;candidate=None
        for sample in samples:
            web.book_id=sample['book_id'];web.chapter=sample['chapter_uid']
            pos_url=BASE+'/web/book/getProgress?'+urlencode({'bookId':web.book_id})
            before=baseline_position(web.request('search_progress_before',pos_url),web.book_id)
            record,chapters=readable_chapters(web.request('search_catalog_before',BASE+'/web/book/chapterInfos',{'bookIds':[web.book_id]}),web.book_id)
            if before!=sample['baseline'] or chapters!=sample['chapters']:raise ValueError('baseline_changed')
            web.first_chapter=str(chapters[0]['chapterUid'])
            ids={str(row['chapterUid']) for row in chapters};attempts=[]
            queries=segment_queries(sample['source']) if sample['source_format']=='web_xhtml' else []
            for index,(keyword,expected) in enumerate(queries,1):
                if restricted:break
                pair={}
                for role,uid in (('current',web.chapter),('first',str(chapters[0]['chapterUid']))):
                    if restricted:break
                    if role=='first' and uid==web.chapter:continue
                    web.keyword=keyword;web.search_cursor={'chapter':uid,'start':0,'finish':0}
                    web.search_url=BASE+'/web/book/search_v2?'+urlencode({'bookId':web.book_id,'chapterUid':uid,
                        'keyword':keyword,'posBegin':0,'posEnd':0,'mode':'scrollDown','count':50})
                    report['search_gets']+=1
                    row={'length':len(keyword),'start':role,'response_valid':False,'target_found':False,
                        'target_matches_source':False,'known_chapters':False}
                    try:
                        value=web.request('segment_'+str(index)+'_'+role,web.search_url)
                        rows=value.get('results',[]);more=value.get('scrollDownHasMore')
                        if not isinstance(rows,list) or len(rows)>200 or type(more) is not int or more not in (0,1):raise ValueError('response')
                        matches=[];known=True
                        for item in rows:
                            if not isinstance(item,dict) or not isinstance(item.get('matchWords'),list):raise ValueError('response')
                            known=known and str(item.get('chapterUid')) in ids
                            for word in item['matchWords']:
                                if not isinstance(word,dict):raise ValueError('response')
                                if str(item.get('chapterUid'))==web.chapter and word.get('word')==keyword:
                                    matches.append((word.get('posBegin'),word.get('posEnd')))
                        row.update(response_valid=True,rows=len(rows),more=more==1,known_chapters=known,
                            target_found=bool(matches),target_matches_source=expected in matches)
                    except PreflightError:
                        event=web.report['stages'][-1];row['http_status']=event.get('status',0)
                        if row['http_status'] in (401,429) or event.get('api_code') is not None:restricted=True
                    attempts.append(row)
                    pair[role]=row
                if (candidate is None and 'current' in pair and 'first' in pair
                        and pair['current']['response_valid'] and pair['current']['target_matches_source']
                        and pair['first']['response_valid'] and pair['first']['rows']==0 and not pair['first']['more']):
                    candidate=(sample,keyword,expected)
            after=baseline_position(web.request('search_progress_after',pos_url),web.book_id)
            later,later_chapters=readable_chapters(web.request('search_catalog_after',BASE+'/web/book/chapterInfos',{'bookIds':[web.book_id]}),web.book_id)
            if before!=after or chapters!=later_chapters or versions(record)!=versions(later):raise ValueError('baseline_changed')
            observations.append({'queries':attempts,'position_unchanged':True,'catalog_unchanged':True})
        native_ui=[]
        if args.native_ui:
            phase='native_ui'
            if not candidate or restricted:raise ValueError('ui_no_sample')
            sample,keyword,expected=candidate;web.book_id=sample['book_id'];web.chapter=sample['chapter_uid']
            web.psvts=sample['context']['psvts']
            pos_url=BASE+'/web/book/getProgress?'+urlencode({'bookId':web.book_id})
            before=baseline_position(web.request('ui_progress_before',pos_url),web.book_id)
            first,chapters=readable_chapters(web.request('ui_catalog_before',BASE+'/web/book/chapterInfos',{'bookIds':[web.book_id]}),web.book_id)
            if before!=sample['baseline'] or chapters!=sample['chapters']:raise ValueError('baseline_changed')
            ids=[str(row['chapterUid']) for row in chapters]
            if len(ids)!=len(set(ids)) or web.chapter not in ids or ids[0]==web.chapter:raise ValueError('ui_catalog')
            safe=[]
            for index,row in enumerate(chapters):
                words=row.get('wordCount');words=words if type(words) is int and 0<words<=10000000 else 1
                item={'chapterUid':str(row['chapterUid']),'title':'章节 '+str(index+1),'wordCount':words}
                chapter_index=row.get('chapterIdx')
                if type(chapter_index) is int and 0<=chapter_index<=1000000:item['chapterIdx']=chapter_index
                safe.append(item)
            cookies={c.name:c.value for c in web.cookies if c.name in {'wr_vid','wr_skey','wr_rt','wr_ql','wr_pf'}}
            payload=dict(owner=web.vid,cookies=cookies,book=web.book_id,chapter=web.chapter,chapters=safe,
                source=sample['source'],keyword=keyword,start=expected[0],finish=expected[1],current_fallback=True,
                allowed=[{'chapter':ids[0],'start':0,'finish':0},{'chapter':web.chapter,'start':0,'finish':0}])
            for catalog_missing in (False,True):
                payload['catalog_missing']=catalog_missing
                for width,height,dpi in ((600,800,167),(1264,1680,300)):
                    invoke(payload,args.container,args.runtime,args.source,args.candidate,width,height,dpi)
                    native_ui.append({'width':width,'height':height,'catalog_missing':catalog_missing,'result':'PASS'})
            after=baseline_position(web.request('ui_progress_after',pos_url),web.book_id)
            later,later_chapters=readable_chapters(web.request('ui_catalog_after',BASE+'/web/book/chapterInfos',{'bookIds':[web.book_id]}),web.book_id)
            params=make_content_params(web.book_id,web.chapter,web.psvts,sc=1)
            reread=decode_content_shards(*(web.request('ui_'+kind,BASE+'/web/book/chapter/'+kind,params,as_json=False)
                for kind in ('e_0','e_1','e_3')))
            if before!=after or chapters!=later_chapters or versions(first)!=versions(later) or reread!=sample['source']:
                raise ValueError('baseline_changed')
        phase='readback';shelf=web.request('shelf_after',BASE+'/web/shelf/sync')
        if [str(row['bookId']) for row in shelf['books']]!=web.shelf_ids:raise ValueError('baseline_changed')
        web.verify_account();save_refreshed_web_session(store,saved,web)
        report.update(result='CB_SEGMENT_SEARCH_CHECKED',books=len(samples),observations=observations,shelf_unchanged=True,
            searches_stopped_on_rejection=restricted,native_ui=native_ui)
    except Exception as exc:
        report['phase']=phase
        if str(exc) in {'baseline_changed','search_scope','search_repeated','http_rejected','api_rejected'}:report['reason']=str(exc)
    finally:
        web.close()
        if saved:saved.clear()
    print(json.dumps(report,ensure_ascii=False));return int(report['result']!='CB_SEGMENT_SEARCH_CHECKED')


if __name__=='__main__':raise SystemExit(main())
