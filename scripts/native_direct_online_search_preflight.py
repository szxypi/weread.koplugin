"""Bounded read-only preparation for native online-search owner validation."""
import re
from urllib.parse import urlencode

from fetch_weread_epub import decode_content_shards,make_content_params,normalize_chapter_infos,read_reader_state,reader_url_for
from verify_owner_book_search_ui import readable_catalog
from verify_source_coordinates import FilteredSource
from verify_web_source_progress import BASE


def prepare(web,book,chapter,native_source):
    web.book_id=book;web.chapter=chapter;web.verify_account()
    reader=read_reader_state(web.request('reader',reader_url_for(book,chapter),as_json=False))
    params=make_content_params(book,chapter,reader.psvts,sc=1)
    raw=decode_content_shards(*(web.request(key,BASE+'/web/book/chapter/'+key,params,as_json=False)
                                 for key in ('e_0','e_1','e_3')))
    if raw.encode()!=native_source:raise ValueError('source_changed')
    _,catalog=normalize_chapter_infos(web.request('catalog_before',BASE+'/web/book/chapterInfos',{'bookIds':[book]}),book)
    chapters=readable_catalog(catalog);ids=[str(row.get('chapterUid')) for row in chapters]
    if not ids or chapter not in ids or len(ids)!=len(set(ids)) or any(not re.fullmatch('[1-9][0-9]{0,19}',uid) for uid in ids):
        raise ValueError('catalog')
    model=FilteredSource(raw);text=''.join(model.characters);keyword=index=None
    for i in range(min(len(text)-12,20000)):
        candidate=text[i:i+12]
        if re.fullmatch('[\u4e00-\u9fff]{12}',candidate) and text.count(candidate)==1:
            keyword,index=candidate,i;break
    if keyword is None:raise ValueError('keyword')
    start,finish=model.starts[index],model.ends[index+len(keyword)-1]
    cursor={'chapter':ids[0],'start':0,'finish':0};allowed=[];seen=set()
    for _ in range(4):
        allowed.append(dict(cursor))
        web.search_url=BASE+'/web/book/search_v2?'+urlencode(dict(bookId=book,chapterUid=cursor['chapter'],
            keyword=keyword,posBegin=cursor['start'],posEnd=cursor['finish'],mode='scrollDown',count=50))
        response=web.request('search_probe',web.search_url);rows=response.get('results',[]);more=response.get('scrollDownHasMore')
        if not isinstance(rows,list) or len(rows)>200 or type(more) is not int or more not in (0,1):raise ValueError('page')
        for row in rows:
            if not isinstance(row,dict) or str(row.get('chapterUid')) not in ids or not isinstance(row.get('matchWords'),list):
                raise ValueError('page')
            if str(row['chapterUid'])==chapter:
                for word in row['matchWords']:
                    if (isinstance(word,dict) and word.get('word')==keyword and word.get('posBegin')==start
                            and word.get('posEnd')==finish):
                        return dict(keyword=keyword,start=start,finish=finish,allowed=allowed)
        if more==0 or not rows:break
        last=rows[-1];cursor={'chapter':str(last.get('chapterUid')),'start':last.get('posBegin'),'finish':last.get('posEnd')}
        marker=(cursor['chapter'],cursor['start'],cursor['finish'])
        if cursor['chapter'] not in ids or any(type(cursor[k]) is not int or cursor[k]<0 for k in ('start','finish')) or marker in seen:
            raise ValueError('cursor')
        seen.add(marker)
    raise ValueError('no_target')
