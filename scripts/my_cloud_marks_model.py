"""Independent display-only own bookmark snapshot; never derives upload ranges."""
import re


def identifier(value):
    return isinstance(value,str) and re.fullmatch('[1-9][0-9]{0,19}',value) is not None


def text(value,limit,empty=True):
    return (isinstance(value,str) and (empty or bool(value)) and len(value.encode())<=limit
            and not re.search(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]',value))


def integer(value,maximum):return type(value) is int and 0<=value<=maximum


def project(source,identity,owner,now):
    if not identifier(identity) or not integer(now,2**53-1) or now==0:raise ValueError('my_marks_scope')
    def scope(value):
        if not isinstance(value,dict):raise ValueError('my_marks_object')
        for key in ('bookId','book_id'):
            if value.get(key) is not None and str(value[key])!=identity:raise ValueError('my_marks_book')
        for key in ('userVid','vid'):
            if owner is not None and value.get(key) is not None and str(value[key])!=owner:raise ValueError('my_marks_owner')
    scope(source)
    for key in ('errcode','errCode'):
        if source.get(key) is not None and (type(source[key]) is not int or source[key]!=0):raise ValueError('my_marks_rejected')
    if source.get('succ') not in (None,True,1):raise ValueError('my_marks_rejected')
    if source.get('hasMore') not in (None,False,0):raise ValueError('my_marks_incomplete')
    if source.get('book') is not None:scope(source['book'])
    rows=source.get('updated');chapters=source.get('chapters',[])
    if not isinstance(rows,list) or len(rows)>5000 or not isinstance(chapters,list) or len(chapters)>5000:raise ValueError('my_marks_rows')
    result=dict(schema=1,book_id=identity,fetched_at=now,updated=[],chapters=[]);seen=set()
    for row in rows:
        scope(row);key=row.get('bookmarkId')
        if not text(key,256,False) or re.search(r'\s',key) or key in seen:raise ValueError('my_marks_identity')
        seen.add(key);item=dict(bookmarkId=key)
        for name,limit in [('markText',131072),('abstract',65536),('range',256)]:
            value=row.get(name)
            if value is not None:
                if not text(value,limit):raise ValueError('my_marks_text')
                item[name]=value
        for name in ('chapterUid','chapterIdx','type','style','colorStyle','createTime'):
            value=row.get(name)
            if value is not None:
                if not integer(value,4102444800 if name=='createTime' else 2147483647):raise ValueError('my_marks_number')
                item[name]=value
        result['updated'].append(item)
    seen=set()
    for row in chapters:
        scope(row);uid=row.get('chapterUid');title=row.get('title')
        if not integer(uid,2147483647) or uid in seen or not text(title,4096,False):raise ValueError('my_marks_chapter')
        seen.add(uid);result['chapters'].append(dict(chapterUid=uid,title=title))
    return result
