"""Source-bound point reference, independently checked before native dispatch."""
import re
from bookmark_point import point_range
from my_cloud_marks_model import identifier,integer,text
from selection_quote import normalized


def validate(row,book):
    source=row.get('source') if isinstance(row,dict) else None
    if (not isinstance(source,dict) or set(source)!={'book_id','chapter_uid','chapter_idx','raw_sha256','raw_bytes'}
            or not identifier(book) or source['book_id']!=book or not identifier(source['chapter_uid'])
            or not integer(source['chapter_idx'],1000000) or not integer(source['raw_bytes'],2*1024*1024) or source['raw_bytes']==0
            or not isinstance(source['raw_sha256'],str) or not re.fullmatch('[a-f0-9]{64}',source['raw_sha256'])
            or row.get('bookmark') is not True or type(row.get('type')) is not int or row['type']!=0
            or not integer(row.get('chapterUid'),2147483647) or str(row['chapterUid'])!=source['chapter_uid']
            or not integer(row.get('chapterIdx'),1000000) or row['chapterIdx']!=source['chapter_idx']
            or not text(row.get('markText'),4096,False) or not normalized(row['markText'])):raise ValueError('bookmark_reference/reference')
    point_range(row.get('range'))
    if row.get('bookmarkId')!='bookmark:'+source['chapter_uid']+':'+row['range']+':'+source['raw_sha256']:raise ValueError('bookmark_reference/id')
    return row


def reference(book,uid,index,value):
    row=dict(bookmark=True,type=0,bookmarkId='bookmark:'+uid+':'+value['range']+':'+value['raw_sha256'],
        range=value['range'],chapterUid=int(uid),chapterIdx=index,markText=value['markText'],
        source=dict(book_id=book,chapter_uid=uid,chapter_idx=index,raw_sha256=value['raw_sha256'],raw_bytes=value['raw_bytes']))
    return validate(row,book)
