"""Exact own-highlight raw range -> both filtered-source boundaries."""
import hashlib
import re
from my_cloud_marks_model import identifier,integer,text
from selection_quote import Selection,normalized


def project(raw,book,chapter,row):
    if (not identifier(book) or not identifier(chapter) or not isinstance(row,dict) or type(row.get('type')) is not int or row['type']!=1
            or not integer(row.get('chapterUid'),2147483647) or str(row['chapterUid'])!=chapter
            or any(str(row[k])!=book for k in ('bookId','book_id') if k in row)
            or not text(row.get('markText'),131072,False)):raise ValueError('my_mark_span/scope')
    marker=row.get('range')
    if not isinstance(marker,str):raise ValueError('my_mark_span/range')
    match=re.fullmatch(r'([0-9]{1,10})-([0-9]{1,10})',marker)
    if not match or not 0<=int(match[1])<int(match[2])<=2147483647:raise ValueError('my_mark_span/range')
    model=Selection(raw);first,last=map(int,match.groups())
    if last>len(model.quotes.raw) or model.quotes.quote(marker).strip()!=row['markText'].strip():raise ValueError('my_mark_span/quote')
    indices=[n for n,(a,b) in enumerate(model.spans) if first<=a and b<=last]
    if not indices or model.flat[indices[0]:indices[-1]+1]!=normalized(row['markText']):raise ValueError('my_mark_span/quote')
    a=model.filtered.starts[model.visible[indices[0]]];b=model.filtered.ends[model.visible[indices[-1]]]
    if model.boundary(a)!=indices[0] or model.boundary(b)!=indices[-1]+1:raise ValueError('my_mark_span/boundary')
    clean=normalized(row['markText']).encode()
    return dict(first=a,last=b,normalized_sha256=hashlib.sha256(clean).hexdigest(),normalized_bytes=len(clean),
                raw_sha256=hashlib.sha256(raw.encode()).hexdigest(),raw_bytes=len(raw.encode()))


def verify_anchor(raw,point,anchor):
    model=Selection(raw);index=model.boundary(point)
    if (not isinstance(anchor,dict) or anchor.get('co')!=point or anchor.get('basis')!='filtered_xhtml_utf16'
            or anchor.get('point_unit')!='unicode_scalars' or type(anchor.get('point_offset')) is not int
            or not isinstance(anchor.get('text'),str) or normalized(anchor['text'])!=anchor['text'] or len(anchor['text'])<12):raise ValueError('my_mark_span/anchor')
    at=model.flat.find(anchor['text'])
    if at<0 or model.flat.find(anchor['text'],at+1)>=0 or at+anchor['point_offset']!=index:raise ValueError('my_mark_span/anchor')
    return True
