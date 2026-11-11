"""Own remote highlight -> source-bound local navigation, never an upload.

The server range is checked as raw Unicode indices (without a leading BOM).
Only after its visible text matches the saved quote do contextual, independent
filtered-source coordinates identify the first visible selected character.
"""
import hashlib
import re

from annotation_source_quotes import SourceQuotes
from my_cloud_marks_model import identifier,integer,text
from verify_source_coordinates import FilteredSource,CoordinateError


def fail(reason):raise ValueError('my_mark_target/'+reason)


def flat(value):return ''.join(char for char in value if not char.isspace())


def project(raw,book,chapter,row):
    if not identifier(book) or not identifier(chapter):fail('scope')
    if (not isinstance(row,dict) or row.get('type')!=1 or type(row.get('type')) is not int
            or str(row.get('chapterUid'))!=chapter or not integer(row.get('chapterUid'),2147483647)
            or row.get('bookId') is not None and str(row['bookId'])!=book):fail('scope')
    quote=row.get('markText')
    if not text(quote,131072,False) or not flat(quote):fail('quote')
    marker=row.get('range');match=re.fullmatch(r'([0-9]{1,10})-([0-9]{1,10})',marker) if isinstance(marker,str) else None
    if not match or not 0<=int(match[1])<int(match[2])<=2147483647:fail('range')
    try:source=SourceQuotes(raw,body_only=True)
    except (ValueError,UnicodeError):fail('source')
    start,end=map(int,match.groups())
    # A real range included an edge newline omitted by markText. Only trim
    # boundaries; different internal whitespace/text still refuses navigation.
    if end>len(source.raw) or source.quote(marker).strip()!=quote.strip():fail('quote_changed')
    try:filtered=FilteredSource(raw,allow_multiple_bodies=True)
    except CoordinateError:fail('source_unsupported')
    visible=[index for index,char in enumerate(filtered.characters) if not char.isspace()]
    haystack=''.join(filtered.characters[index] for index in visible)
    points=set();needle=flat(quote);selected=needle[:1024]
    contexts=[('',selected,'')]
    for width in (24,48,96,192):
        before=source.quote(f'{max(0,start-width)}-{start}') if start else ''
        after=source.quote(f'{end}-{min(len(source.raw),end+width)}') if end<len(source.raw) and len(needle)<=1024 else ''
        contexts.extend(((before,selected,after),('',selected,after),(before,selected,'')))
    for before,selected,after in contexts:
        prefix=flat(before);candidate=prefix+flat(selected)+flat(after)
        if len(candidate)<12:continue
        at=haystack.find(candidate)
        if at<0 or haystack.find(candidate,at+1)>=0:continue
        index=at+len(prefix)
        if not haystack.startswith(needle,index):continue
        points.add(filtered.starts[visible[index]])
    if len(points)!=1:fail('ambiguous' if points else 'unmatched')
    offset=points.pop()
    # The filtered coordinate must identify exactly one visible boundary.
    # The later archive/DOM binding still decides whether navigation succeeds.
    aliases={i for i,value in enumerate(filtered.starts) if value==offset}
    aliases.update(i+1 for i,value in enumerate(filtered.ends) if value==offset)
    if len(aliases)!=1 or any(a<offset<b for a,b in zip(filtered.starts,filtered.ends)):fail('boundary')
    return dict(book_id=book,chapter_uid=chapter,chapter_offset=offset,
                raw_sha256=hashlib.sha256(raw.encode()).hexdigest(),raw_bytes=len(raw.encode()),
                basis='filtered_xhtml_utf16',upload_verified=False)
