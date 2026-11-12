"""Read-only identity of a selected chapter, independent of cloud progress."""
import hashlib
import math
import re

from fetch_weread_epub import decode_content_shards,make_content_params,reader_url_for
from source_upload_candidate import identifier,chapter_index
from verify_reader_context import project as reader_context
from verify_web_source_progress import BASE

FIELDS={'book_id','chapter_uid','chapter_idx','raw_sha256','raw_bytes'}
VERSION_FIELDS=('bookVersion','version','contentVersion')


def validate_expected(value):
    if not isinstance(value,dict) or set(value)!=FIELDS:raise ValueError('source_expected')
    if identifier(value['book_id'])!=value['book_id'] or identifier(value['chapter_uid'])!=value['chapter_uid']:
        raise ValueError('source_expected')
    if type(value['chapter_idx']) is not int or not 0<=value['chapter_idx']<=1000000:raise ValueError('source_expected')
    if (not isinstance(value['raw_sha256'],str) or not re.fullmatch('[0-9a-f]{64}',value['raw_sha256'])
            or type(value['raw_bytes']) is not int or not 1<=value['raw_bytes']<=2*1024*1024):raise ValueError('source_expected')
    return value


def version(value):
    if value is None:return ''
    if type(value) in (int,float) and math.isfinite(value) and value%1==0 and 0<=value<=9007199254740991:return str(int(value))
    if isinstance(value,str) and re.fullmatch('[0-9]{1,19}',value):return value.lstrip('0') or '0'
    raise ValueError('source_catalog')


def catalog(payload,book,uid):
    def success(value):
        if not isinstance(value,dict):return
        for key in ('errcode','errCode'):
            if key in value and value[key] is not None and (type(value[key]) not in (int,float,str) or value[key] not in (0,'0')):
                raise ValueError('source_catalog')
        if 'succ' in value and value['succ'] is not None and not (value['succ'] is True or type(value['succ']) in (int,float,str) and value['succ'] in (1,'1')):
            raise ValueError('source_catalog')
    success(payload)
    candidates=payload if isinstance(payload,list) else payload.get('data',payload.get('books',payload)) if isinstance(payload,dict) else None
    if isinstance(candidates,dict) and ('bookId' in candidates or 'book' in candidates):candidates=[candidates]
    if not isinstance(candidates,list) or len(candidates)>10000:raise ValueError('source_catalog')
    selected=[]
    for item in candidates:
        if not isinstance(item,dict):continue
        nested=item.get('book')
        returned=item.get('bookId') or (nested.get('bookId') if isinstance(nested,dict) else None)
        if str(returned)==book:selected.append(item)
    if len(selected)!=1:raise ValueError('source_catalog')
    record=selected[0]
    rows=next((record[key] for key in ('updated','chapterInfos','chapters') if record.get(key) is not None),None)
    success(record)
    index=chapter_index(rows,uid)
    row=next(r for r in rows if str(r.get('chapterUid',r.get('chapterId',r.get('chapter_uid'))))==uid)
    nested=record.get('book')
    if nested is not None and (not isinstance(nested,dict) or 'bookId' in nested and identifier(nested['bookId'])!=book):
        raise ValueError('source_catalog')
    pieces=[book,uid,str(index)]
    for node in (record,nested or {},row):
        pieces.extend(version(node.get(key)) for key in VERSION_FIELDS)
    return index,hashlib.sha256('\0'.join(pieces).encode()).hexdigest()


def project(expected,before,reader,raw,after):
    validate_expected(expected)
    book,uid=expected['book_id'],expected['chapter_uid']
    first,last=catalog(before,book,uid),catalog(after,book,uid)
    if first!=last or first[0]!=expected['chapter_idx']:raise ValueError('source_catalog_changed')
    if (not isinstance(reader,dict) or reader.get('book_id')!=book or not isinstance(reader.get('psvts'),str)
            or not re.fullmatch('[!-~]{1,4096}',reader['psvts'])):raise ValueError('source_reader')
    if not isinstance(raw,str) or not 1<=len(raw.encode())<=2*1024*1024:raise ValueError('source_invalid')
    if hashlib.sha256(raw.encode()).hexdigest()!=expected['raw_sha256'] or len(raw.encode())!=expected['raw_bytes']:
        raise ValueError('source_changed')
    return dict(expected,catalog_stamp=first[1],source_current=True,upload_verified=False)


def inspect(probe,book,uid,expected=None):
    probe.book_id,probe.chapter=identifier(book),identifier(uid)
    probe.verify_account()
    before=probe.request('catalog_before',BASE+'/web/book/chapterInfos',dict(bookIds=[book]))
    index,_stamp=catalog(before,book,uid)
    html=probe.request('reader',reader_url_for(book,uid),as_json=False)
    reader=reader_context(dict(book_id=book),html)
    params=make_content_params(book,uid,reader['psvts'],sc=1)
    raw=decode_content_shards(*(probe.request(name,BASE+'/web/book/chapter/'+name,params,as_json=False) for name in ('e_0','e_1','e_3')))
    after=probe.request('catalog_after',BASE+'/web/book/chapterInfos',dict(bookIds=[book]))
    probe.verify_account()
    if expected is None:expected=dict(book_id=book,chapter_uid=uid,chapter_idx=index,raw_sha256=hashlib.sha256(raw.encode()).hexdigest(),raw_bytes=len(raw.encode()))
    result=project(expected,before,reader,raw,after)
    return result,dict(expected=expected,before=before,reader=reader,raw=raw,after=after)
