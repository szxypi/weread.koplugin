"""Bounded display-only projection of the native notebook response."""
import math
import re

MAX_ROWS=5000
COUNTS=('noteCount','reviewCount','bookmarkCount')


def text(value,limit,empty=False):
    if not isinstance(value,str) or (not empty and not value) or len(value.encode('utf-8'))>limit:
        raise ValueError('notebook/text')
    if re.search(r'[\x00-\x1f\x7f]',value):raise ValueError('notebook/text')
    return value


def ident(value):
    if type(value) is int and 1<=value<=9007199254740991:value=str(value)
    value=text(value,256)
    if re.search(r'\s',value):raise ValueError('notebook/id')
    return value


def number(value,maximum=2147483647):
    if type(value) not in (int,float) or not math.isfinite(value) or not 0<=value<=maximum or value%1:
        raise ValueError('notebook/number')
    return int(value)


def project(source,now):
    if not isinstance(source,dict) or not isinstance(source.get('books'),list) or len(source['books'])>MAX_ROWS:
        raise ValueError('notebook/rows')
    if any(source.get(key) not in (None,0) or type(source.get(key)) is bool for key in ('errcode','errCode')):
        raise ValueError('notebook/rejected')
    if 'succ' in source and source['succ'] not in (True,1):raise ValueError('notebook/rejected')
    if number(source.get('totalBookCount'),MAX_ROWS)!=len(source['books']):raise ValueError('notebook/incomplete')
    if 'hasMore' in source and not (source['hasMore'] is False or type(source['hasMore']) is int and source['hasMore']==0):
        raise ValueError('notebook/incomplete')
    number(now,2**53-1)
    if now==0:raise ValueError('notebook/time')
    rows=[];seen=set()
    for value in source['books']:
        if not isinstance(value,dict) or not isinstance(value.get('book'),dict):raise ValueError('notebook/row')
        book=value['book'];identity=ident(value.get('bookId'))
        if ident(book.get('bookId'))!=identity or identity in seen:raise ValueError('notebook/id')
        seen.add(identity)
        author=book.get('author')
        row=dict(bookId=identity,title=text(book.get('title'),4096),author=text('' if author is None else author,4096,True))
        for field in COUNTS:
            if field in value and value[field] is not None:row[field]=number(value[field])
        if 'sort' in value and value['sort'] is not None:row['sort']=number(value['sort'],2**53-1)
        rows.append(row)
    return dict(schema=1,fetched_at=now,books=rows)
