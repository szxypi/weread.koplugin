#!/usr/bin/env python3
"""One bounded, read-only search probe; private values never leave memory."""
import argparse
import json
import re
import resource
import subprocess
from collections import Counter
from urllib.parse import urlencode

from fetch_weread_epub import decode_content_shards,make_content_params,normalize_chapter_infos,read_reader_state,reader_url_for
from secure_weread_session import SessionStore
from verify_source_coordinates import FilteredSource
from verify_translation_preflight import save_refreshed_web_session
from verify_web_source_progress import BASE,WebSourceProbe,position,versions


class Probe(WebSourceProbe):
    search_url=None
    def guard(self,stage,url,body):
        if (stage=='search_probe' and self.authenticated and body is None and self.search_url
                and url==self.search_url and url.startswith(BASE+'/web/book/search_v2?')):
            return
        return super().guard(stage,url,body)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--saved-session',action='store_true')
    parser.add_argument('--container',default='weread-validation')
    parser.add_argument('--runtime',default='/validation/runtime/lib/koreader')
    parser.add_argument('--source',default='/source')
    args=parser.parse_args(argv)
    if (not re.fullmatch('[A-Za-z0-9_.-]{1,128}',args.container)
            or any(not path.startswith('/') or '\x00' in path for path in (args.runtime,args.source))):
        parser.error('invalid isolated runtime')
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    report={'result':'OFFLINE_ONLY','account_data_posts':0,'authentication_posts':0,'search_gets':0}
    if not args.saved_session:
        print(json.dumps(report));return 0
    report['result']='UNVERIFIED'
    web=Probe();saved=None
    try:
        store=SessionStore();saved=store.load();web.vid=saved['vid']
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();book=web.select_shelf_book()
        before=position(web.request('progress_before',BASE+'/web/book/getProgress?'+urlencode({'bookId':book})),book)
        web.chapter=before['chapter']
        state=read_reader_state(web.request('reader',reader_url_for(book,web.chapter),as_json=False))
        if state.book_id!=book or str(state.current_chapter.get('chapterUid'))!=web.chapter:raise ValueError('reader')
        cat=web.request('catalog_before',BASE+'/web/book/chapterInfos',{'bookIds':[book]})
        record,chapters=normalize_chapter_infos(cat,book)
        if sum(str(item.get('chapterUid'))==web.chapter for item in chapters)!=1:raise ValueError('chapter')
        params=make_content_params(book,web.chapter,state.psvts,sc=1)
        raw=decode_content_shards(*(web.request(k,BASE+'/web/book/chapter/'+k,params,as_json=False) for k in ('e_0','e_1','e_3')))
        model=FilteredSource(raw);text=''.join(model.characters);keyword=None;index=None
        for i in range(min(len(text)-4,20000)):
            candidate=text[i:i+4]
            if re.fullmatch('[\u4e00-\u9fff]{4}',candidate) and text.count(candidate)==1:
                keyword,index=candidate,i;break
        if keyword is None:raise ValueError('keyword')
        start,end=model.starts[index],model.ends[index+len(keyword)-1]
        web.search_url=BASE+'/web/book/search_v2?'+urlencode({'bookId':book,'chapterUid':web.chapter,'keyword':keyword,
            'posBegin':0,'posEnd':0,'mode':'scrollDown','count':50})
        report['search_gets']=1
        result=web.request('search_probe',web.search_url)
        rows=result.get('results',[]);flag=result.get('scrollDownHasMore')
        if not isinstance(rows,list) or type(flag) is not int or flag not in (0,1) or len(rows)>100:raise ValueError('response')
        matches=[]
        for row in rows:
            if not isinstance(row,dict) or not isinstance(row.get('matchWords'),list):raise ValueError('row')
            for item in row['matchWords']:
                if not isinstance(item,dict):raise ValueError('match')
                if str(row.get('chapterUid'))==web.chapter and item.get('word')==keyword:
                    matches.append((item.get('posBegin'),item.get('posEnd')))
        counts=Counter(text[i:i+2] for i in range(len(text)-1) if re.fullmatch('[\u4e00-\u9fff]{2}',text[i:i+2]))
        repeated=next((word for word,n in counts.most_common() if 8<=n<=200),None)
        report['pagination_sample_available']=repeated is not None
        if repeated:
            cursor_chapter=web.chapter;cursor=(0,0);seen=set();observed=set();chapters_seen=set();page_count=0;repeat_flag=None
            largest_page=0
            pages=[];expected_keys=set()
            chapter_order={str(item.get('chapterUid')):i for i,item in enumerate(chapters)}
            previous=None;ordered=True;unknown=0
            catalog_ids={str(item.get('chapterUid')) for item in chapters}
            for _page in range(4):
                web.search_url=BASE+'/web/book/search_v2?'+urlencode({'bookId':book,'chapterUid':cursor_chapter,'keyword':repeated,
                    'posBegin':cursor[0],'posEnd':cursor[1],'mode':'scrollDown','count':5})
                report['search_gets']+=1;data=web.request('search_probe',web.search_url);page_count+=1
                page=data.get('results',[]);repeat_flag=data.get('scrollDownHasMore');pages.append(data)
                report['last_page_rows']=len(page) if isinstance(page,list) else -1
                report['last_more_type']=type(repeat_flag).__name__
                if not isinstance(page,list) or type(repeat_flag) is not int or repeat_flag not in (0,1) or len(page)>100:raise ValueError('pagination')
                largest_page=max(largest_page,len(page))
                for row in page:
                    if not isinstance(row,dict) or not isinstance(row.get('matchWords'),list):raise ValueError('pagination_row')
                    chapters_seen.add(str(row.get('chapterUid')))
                    uid=str(row.get('chapterUid'));startpos=row.get('posBegin');endpos=row.get('posEnd')
                    if uid not in chapter_order:unknown+=1
                    elif type(startpos) is int and type(endpos) is int:
                        point=(chapter_order[uid],startpos,endpos)
                        if previous is not None and point<previous:ordered=False
                        previous=point
                    for item in row['matchWords']:
                        if item.get('word')==repeated and type(item.get('posBegin')) is int and type(item.get('posEnd')) is int:
                            expected_keys.add(str(row.get('chapterUid'))+':'+str(item['posBegin'])+':'+str(item['posEnd']))
                        if str(row.get('chapterUid'))==web.chapter and item.get('word')==repeated:
                            observed.add((item.get('posBegin'),item.get('posEnd')))
                if repeat_flag==0:break
                if not page:raise ValueError('pagination_empty')
                cursor_chapter=str(page[-1].get('chapterUid'));cursor=(page[-1].get('posBegin'),page[-1].get('posEnd'))
                stamp=(cursor_chapter,*cursor)
                if cursor_chapter not in catalog_ids or any(type(v) is not int or v<0 for v in cursor) or stamp in seen:raise ValueError('pagination_cursor')
                seen.add(stamp)
            expected={(model.starts[i],model.ends[i+1]) for i in range(len(text)-1) if text[i:i+2]==repeated}
            visible_expected=set(expected)
            for i,c in enumerate(text):
                if c!=repeated[0]:continue
                j=i+1
                while j<len(text) and text[j].isspace():j+=1
                if j<len(text) and text[j]==repeated[1]:visible_expected.add((model.starts[i],model.ends[j]))
            mismatch=observed-expected
            if len(mismatch)==1:
                first,last=next(iter(mismatch));raw16=raw.encode('utf-16-le')
                segment=raw16[first*2:last*2].decode('utf-16-le',errors='replace') if type(first) is int and type(last) is int else ''
                report.update(mismatch_width=last-first,raw_slice_exact=segment==repeated,
                    raw_slice_contains_keyword=repeated in segment,raw_slice_has_markup='<' in segment or '>' in segment,
                    mismatch_start_at_first_character=any(c==repeated[0] and model.starts[i]==first for i,c in enumerate(model.characters)),
                    mismatch_end_at_second_character=any(c==repeated[1] and model.ends[i]==last for i,c in enumerate(model.characters)))
            report.update(pagination_pages=page_count,pagination_exhausted=repeat_flag==0,
                pagination_distinct_chapters=len(chapters_seen),pagination_target_matches=len(observed),
                pagination_source_ranges_valid=bool(observed) and observed<=expected,
                matching_ranges=len(observed & expected),unexpected_ranges=len(observed-expected),
                nonstandard_width_ranges=sum(type(a) is not int or type(b) is not int or b-a!=2 for a,b in observed),
                whitespace_normalized_valid=bool(observed) and observed<=visible_expected,
                rows_follow_catalog_order=ordered,unknown_chapter_rows=unknown,
                max_page_rows=largest_page,requested_page_size=5)
            payload=dict(book=book,keyword=repeated,first=web.chapter,
                chapters=[{'chapterUid':item.get('chapterUid')} for item in chapters],pages=pages,expected_keys=list(expected_keys))
            command=['docker','exec','-i','-w',args.runtime,args.container,
                     './luajit',args.source+'/spec/koreader/book_search_probe.lua',args.source]
            child=subprocess.run(command,input=json.dumps(payload,ensure_ascii=False,separators=(',',':')).encode(),
                stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=30)
            marker=b'\nWEREAD_BOOK_SEARCH_MODEL='
            if child.stdout.count(marker)!=1:raise ValueError('model')
            model_report=json.loads(child.stdout.split(marker)[1]);report['lua_model']=model_report
            if child.returncode:raise ValueError('model')
            target_payload=dict(book=book,chapter=web.chapter,keyword=repeated,raw=raw,
                hits=[dict(start=a,finish=b,nonstandard=b-a!=2) for a,b in sorted(observed)])
            target_command=['docker','exec','-i','-w',args.runtime,args.container,'sh','-c',
                'ulimit -c 0; exec "$@"','sh','xvfb-run','-a','./luajit',
                args.source+'/spec/koreader/book_search_target_probe.lua',args.source]
            target_process=subprocess.run(target_command,input=json.dumps(target_payload,ensure_ascii=False,separators=(',',':')).encode(),
                stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=60)
            marker=b'\nWEREAD_BOOK_SEARCH_TARGET='
            if target_process.stdout.count(marker)!=1:raise ValueError('target_model')
            report['target_model']=json.loads(target_process.stdout.split(marker)[1])
            if target_process.returncode:raise ValueError('target_model')
            first_uid=str(chapters[0].get('chapterUid'))
            if first_uid not in catalog_ids:raise ValueError('first_chapter')
            web.search_url=BASE+'/web/book/search_v2?'+urlencode({'bookId':book,'chapterUid':first_uid,'keyword':repeated,
                'posBegin':0,'posEnd':0,'mode':'scrollDown','count':50})
            report['search_gets']+=1
            first_page=web.request('search_probe',web.search_url)
            first_rows=first_page.get('results',[]);first_flag=first_page.get('scrollDownHasMore')
            if not isinstance(first_rows,list) or len(first_rows)>200 or type(first_flag) is not int or first_flag not in (0,1):
                raise ValueError('first_page')
            first_keys=set();first_in_catalog=True
            for row in first_rows:
                if not isinstance(row,dict) or not isinstance(row.get('matchWords'),list):raise ValueError('first_page')
                first_in_catalog=first_in_catalog and str(row.get('chapterUid')) in catalog_ids
                for item in row['matchWords']:
                    if item.get('word')==repeated and type(item.get('posBegin')) is int and type(item.get('posEnd')) is int:
                        first_keys.add(str(row['chapterUid'])+':'+str(item['posBegin'])+':'+str(item['posEnd']))
            report.update(first_chapter_search=True,first_chapter_rows=len(first_rows),
                first_chapter_has_more=first_flag==1,first_chapter_rows_in_catalog=first_in_catalog)
            http_payload=dict(book=book,keyword=repeated,first=first_uid,chapters=payload['chapters'],
                cookies={c.name:c.value for c in web.cookies if c.name in {'wr_vid','wr_skey','wr_rt','wr_ql','wr_pf'}},
                expected_keys=list(first_keys))
            http_command=['docker','exec','-i','-w',args.runtime,args.container,'sh','-c',
                'ulimit -c 0; exec "$@"','sh','xvfb-run','-a','./luajit',
                args.source+'/spec/koreader/book_search_http_probe.lua',args.source]
            http=subprocess.run(http_command,input=json.dumps(http_payload,ensure_ascii=False,separators=(',',':')).encode(),
                stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=60)
            frame=b'\nWEREAD_BOOK_SEARCH_HTTP='
            if http.stdout.count(frame)!=1:raise ValueError('native_http')
            report['lua_http']=json.loads(http.stdout.split(frame)[1])
            if http.returncode:raise ValueError('native_http')
        later,later_chapters=normalize_chapter_infos(web.request('catalog_after',BASE+'/web/book/chapterInfos',{'bookIds':[book]}),book)
        after=position(web.request('progress_after',BASE+'/web/book/getProgress?'+urlencode({'bookId':book})),book)
        web.verify_account();save_refreshed_web_session(store,saved,web)
        if (start,end) not in matches or chapters!=later_chapters or versions(record)!=versions(later) or before!=after:
            raise ValueError('baseline_changed')
        report.update(result='SEARCH_READ_VERIFIED',rows=len(rows),more=flag==1,chapter_hits=len(matches),
            target_in_search=bool(matches),coordinates_match_source=(start,end) in matches,
            catalog_stable=chapters==later_chapters and versions(record)==versions(later),position_stable=before==after)
    except Exception as error:
        if str(error) in {'pagination','pagination_row','pagination_empty','pagination_cursor','keyword','response','row','match','reader','chapter'}:
            report['diagnostic']=str(error)
        report['stage_status']=[{'stage':r.get('stage'),'status':r.get('status')} for r in web.report['stages']]
    finally:
        web.close()
        if saved:saved.clear()
    print(json.dumps(report,ensure_ascii=False))
    return int(report['result']!='SEARCH_READ_VERIFIED')

if __name__=='__main__':raise SystemExit(main())
