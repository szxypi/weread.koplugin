"""Exact filtered UTF-16 position <-> raw HTML scalar bookmark point.

No percentage, text-length addition, fuzzy match or network. Bookmark previews
come from verified original source and are not assumed to be returned by API.
"""
import hashlib
import re
from selection_quote import Selection,normalized
from my_cloud_marks_model import identifier,text as valid_text


def point_range(value):
    if not isinstance(value,str) or not re.fullmatch('[0-9]{1,10}',value):raise ValueError('bookmark_point/range')
    at=int(value)
    if at>2147483647 or str(at)!=value:raise ValueError('bookmark_point/range')
    return at


def first_position(raw):
    model=Selection(raw)
    if not model.visible:raise ValueError('bookmark_point/empty')
    return model.filtered.starts[model.visible[0]]


def project(raw,co):
    model=Selection(raw);index=model.boundary(co)
    if index>=len(model.spans):raise ValueError('bookmark_point/end')
    raw_at=model.spans[index][0]
    # Keep the exact entity boundary; never invent an inner entity/scalar point.
    matches=[i for i,(start,_end) in enumerate(model.spans) if start==raw_at]
    if matches!=[index]:raise ValueError('bookmark_point/entity')
    canonical=model.filtered.starts[model.visible[index]]
    if model.boundary(canonical)!=index:raise ValueError('bookmark_point/boundary')
    visible=[]
    from html import unescape
    for start,end,text,entity in model.quotes.spans:
        if end<=raw_at:continue
        if start<raw_at:
            if entity:raise ValueError('bookmark_point/entity')
            text=text[raw_at-start:]
        visible.extend(unescape(text))
        if len(visible)>=140:break
    preview=''.join(visible[:140]).strip()
    if not valid_text(preview,4096,False):raise ValueError('bookmark_point/preview')
    return dict(range=str(raw_at),markText=preview,chapter_offset=canonical,
                raw_sha256=hashlib.sha256(raw.encode()).hexdigest(),raw_bytes=len(raw.encode()))


def from_mark(raw,book,chapter,row):
    if (not identifier(book) or not identifier(chapter) or not isinstance(row,dict) or type(row.get('type')) is not int or row['type']!=0
            or type(row.get('chapterUid')) is not int or str(row['chapterUid'])!=chapter
            or any(str(row[k])!=book for k in ('bookId','book_id') if k in row)):raise ValueError('bookmark_point/scope')
    raw_at=point_range(row.get('range'));model=Selection(raw)
    indices=[i for i,(start,_end) in enumerate(model.spans) if start==raw_at]
    if len(indices)!=1:raise ValueError('bookmark_point/point')
    co=model.filtered.starts[model.visible[indices[0]]];value=project(raw,co)
    if value['range']!=row['range']:raise ValueError('bookmark_point/boundary')
    preview=row.get('markText')
    if preview is not None and preview!='':
        if not valid_text(preview,131072,False) or not normalized(preview) or not model.flat.startswith(normalized(preview),indices[0]):
            raise ValueError('bookmark_point/preview')
    return dict(book_id=book,chapter_uid=chapter,chapter_offset=co,raw_sha256=value['raw_sha256'],raw_bytes=value['raw_bytes'],
                basis='filtered_xhtml_utf16',upload_verified=False)
