"""Own thought quote -> source-bound local target, never a progress upload.

Only canonical personal-thought snapshots are accepted. A review's raw range
must prove its own abstract; nearby highlights and the thought text cannot
stand in for a missing quoted source.
"""
import re
from my_cloud_marks_model import identifier,integer,text
from my_mark_target import project as highlight_target


def reference(book,chapter,row):
    if (not identifier(book) or not identifier(chapter) or not isinstance(row,dict)
            or not text(row.get('reviewId'),256,False) or any(c.isspace() for c in row['reviewId'])
            or row.get('bookId') is not None and str(row['bookId'])!=book
            or not integer(row.get('chapterUid'),2147483647) or row['chapterUid']==0 or str(row['chapterUid'])!=chapter
            or type(row.get('type')) is not int or row['type']!=1):raise ValueError('my_thought_target/scope')
    quote=row.get('abstract')
    if not text(quote,65536,False) or not quote.strip():raise ValueError('my_thought_target/quote')
    marker=row.get('range');match=re.fullmatch(r'([0-9]{1,10})-([0-9]{1,10})',marker) if isinstance(marker,str) else None
    if not match or not 0<=int(match[1])<int(match[2])<=2147483647:raise ValueError('my_thought_target/range')
    return dict(type=1,chapterUid=row['chapterUid'],markText=quote,range=row.get('range'),bookId=book)


def project(raw,book,chapter,row):
    return highlight_target(raw,book,chapter,reference(book,chapter,row))
