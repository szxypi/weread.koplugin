"""Independent, non-writing projection of an observed XHTML source point."""
import math
import re
from verify_source_coordinates import FilteredSource,CoordinateError


def identifier(value):
    if type(value) is int:value=str(value)
    if not isinstance(value,str) or not re.fullmatch('[1-9][0-9]{0,19}',value):raise ValueError('candidate_identity')
    return value


def chapter_index(chapters,uid):
    if not isinstance(chapters,list) or not 1<=len(chapters)<=10000:raise ValueError('candidate_catalog')
    selected=[]
    for row in chapters:
        if not isinstance(row,dict):raise ValueError('candidate_catalog')
        ids=[identifier(row[k]) for k in ('chapterUid','chapterId','chapter_uid') if k in row]
        if not ids or len(set(ids))!=1:raise ValueError('candidate_catalog')
        if ids[0]!=uid:continue
        indices=[row[k] for k in ('chapterIdx','chapterIndex','chapter_idx') if k in row]
        if not indices or any(type(n) is not int or not 0<=n<=1000000 for n in indices) or len(set(indices))!=1:
            raise ValueError('candidate_catalog')
        selected.append(indices[0])
    if len(selected)!=1:raise ValueError('candidate_catalog')
    return selected[0]


def project(raw,point,chapters,percent):
    if not isinstance(point,dict):raise ValueError('candidate_point')
    book,uid=identifier(point['book_id']),identifier(point['chapter_uid'])
    co=point['chapter_offset']
    if type(co) is not int or not 0<=co<=2147483647:raise ValueError('candidate_point')
    if type(percent) not in (int,float) or not math.isfinite(percent) or percent%1 or not 0<=percent<=100:
        raise ValueError('candidate_percent')
    model=FilteredSource(raw)
    found=[i for i,n in enumerate(model.starts) if n==co]
    if len(found)!=1:raise ValueError('candidate_point')
    index=found[0]
    for width in (24,48,96,192):
        first,last=max(0,index-width),min(len(model.characters),index+width)
        quote=''.join(model.characters[first:last])
        try:
            if model.locate(quote)[0]==model.starts[first]:break
        except CoordinateError:pass
    else:raise ValueError('candidate_ambiguous')
    return dict(book_id=book,chapter_uid=uid,chapter_idx=chapter_index(chapters,uid),chapter_offset=co,
                percent=int(percent),summary=''.join(model.characters[index:index+20]),
                basis='filtered_xhtml_utf16',upload_verified=False)
