"""Independent highlight postconditions; no transport or account persistence."""
from copy import deepcopy
from thought_edit_contract import digest,snapshot_hash as thoughts_hash
from highlight_trial_model import request
from bookmark_reference import validate as bookmark_reference
from bookmark_point import point_range
from my_cloud_marks_model import integer

ROW=('bookmarkId','markText','abstract','range','chapterUid','chapterIdx','type','style','colorStyle','createTime')
MATCH=('markText','range','chapterUid','type','style','colorStyle')
POINT_MATCH=('range','chapterUid','type')
CREATING=('create','bookmark_create')
DELETING=('delete','bookmark_delete')


def fields_hash(row,fields):
    return digest(digest([] if row.get(k) is None else [row[k]]) for k in fields)


def row_hash(row):return fields_hash(row,ROW)


def rows_hash(rows,omit=None):
    chosen=sorted((r for r in rows if r['bookmarkId']!=omit),key=lambda r:r['bookmarkId'])
    if len({r['bookmarkId'] for r in chosen})!=len(chosen):raise ValueError('mark_edit/duplicate')
    return digest(['marks-v1',len(chosen)]+[row_hash(r) for r in chosen])


def chapters_hash(rows,omit=None):
    chosen=sorted((r for r in rows if str(r['chapterUid'])!=omit),key=lambda r:r['chapterUid'])
    return digest(['mark-chapters-v1',len(chosen)]+[fields_hash(r,('chapterUid','title')) for r in chosen])


def body_hash(body):
    if 'bookmarkIds' in body:return digest(['remove-mark-v1',body['bookmarkIds'][0]])
    return digest(['body-v1']+[v for k in sorted(body) for v in (k,body[k])])


def disjoint(rows,reference,*,ignore_bookmarks=False):
    a,b=map(int,reference['range'].split('-'))
    if not 0<=a<b<=2147483647:return False
    for row in rows:
        if row.get('chapterUid')!=reference['chapterUid']:continue
        if ignore_bookmarks and type(row.get('type')) is int and row['type']==0:
            try:point_range(row.get('range'))
            except ValueError:return False
            continue
        try:first,last=map(int,row['range'].split('-'))
        except (KeyError,ValueError,AttributeError):return False
        if not 0<=first<last<=2147483647 or first<b and last>a:return False
    return True


def make(snapshot,operation,reference,metadata=None,*,style=None):
    book=snapshot['book_id'];marks=snapshot['marks'];notes=snapshot['thoughts']
    if operation in CREATING:
        if operation=='bookmark_create':
            bookmark_reference(reference,book)
            for value in marks['updated']:
                if value.get('type')==0 and value.get('chapterUid')==reference['chapterUid']:
                    point_range(value.get('range'))
                    if value['range']==reference['range']:raise ValueError('mark_edit/duplicate')
        elif not reference.get('selection') or not disjoint(marks['updated'],reference,ignore_bookmarks=True):raise ValueError('mark_edit/selection')
        if str(metadata['bookId'])!=book:raise ValueError('mark_edit/metadata')
        row=reference;version=metadata.get('bookVersion',metadata.get('version'))
        if operation=='bookmark_create':
            if not integer(version,2147483647) or version==0:raise ValueError('mark_edit/metadata')
            body=dict(bookId=book,chapterUid=row['chapterUid'],bookVersion=version,type=0,style=0,range=row['range'],markText=row['markText'])
        else:body=request(dict(bookId=book,chapterUid=row['chapterUid'],bookVersion=version,range=row['range'],abstract=row['markText']))
    elif operation in DELETING or operation=='style':
        row=next((r for r in marks['updated'] if r['bookmarkId']==reference['bookmarkId']),None)
        if row is None or row_hash(row)!=row_hash(reference):raise ValueError('mark_edit/changed')
        if operation=='bookmark_delete':
            if type(row.get('type')) is not int or row['type']!=0 or not integer(row.get('chapterUid'),2147483647) or row['chapterUid']==0:raise ValueError('mark_edit/changed')
            point_range(row.get('range'))
        elif row.get('type')!=1:raise ValueError('mark_edit/changed')
        if operation in DELETING:body=dict(bookmarkIds=[row['bookmarkId']])
        else:
            from mark_style_trial_model import style_body
            body=style_body(row,style)
            if style==row.get('style'):raise ValueError('mark_edit/unchanged')
    else:raise ValueError('mark_edit/operation')
    if operation in ('create','delete') and not disjoint(notes['reviews'],row):raise ValueError('mark_edit/linked_thought')
    after=''
    if operation in DELETING:after=rows_hash(marks['updated'],row['bookmarkId'])
    elif operation=='style':
        rows=deepcopy(marks['updated'])
        for value in rows:
            if value['bookmarkId']==row['bookmarkId']:value['style']=style
        after=rows_hash(rows)
    uid=str(row['chapterUid'])
    return dict(snapshot=deepcopy(snapshot),body=body,metadata=dict(book_id=book,operation=operation,target_id=row['bookmarkId'],
        before_hash=rows_hash(marks['updated']),after_hash=after,
        reference_hash=digest([body['markText']]) if operation=='bookmark_create' else row_hash(row),
        match_hash=fields_hash(body,POINT_MATCH if operation=='bookmark_create' else MATCH) if operation in CREATING else '',request_hash=body_hash(body),
        thoughts_hash=thoughts_hash(notes),chapters_hash=chapters_hash(marks['chapters']),
        chapter_without_hash=chapters_hash(marks['chapters'],uid),chapter_uid=uid,
        chapter_present=int(any(str(r['chapterUid'])==uid for r in marks['chapters']))))


def check(snapshot,metadata):
    if snapshot['book_id']!=metadata['book_id']:raise ValueError('mark_edit/book')
    marks=snapshot['marks']
    if thoughts_hash(snapshot['thoughts'])!=metadata['thoughts_hash']:return False,None
    if metadata['operation'] in DELETING or metadata['operation']=='style' or metadata['chapter_present']:
        if chapters_hash(marks['chapters'])!=metadata['chapters_hash']:
            # Real empty-book roundtrip: deleting the chapter's last mark also
            # removes its derived descriptor. Every other descriptor and every
            # remaining mark must still match the exact expected set.
            removed_empty=(metadata['operation'] in DELETING and metadata['chapter_present']==1
                and chapters_hash(marks['chapters'],metadata['chapter_uid'])==metadata['chapter_without_hash']
                and not any(str(r['chapterUid'])==metadata['chapter_uid'] for r in marks['chapters'])
                and not any(str(r.get('chapterUid'))==metadata['chapter_uid'] for r in marks['updated']))
            if not removed_empty:return False,None
    elif chapters_hash(marks['chapters'],metadata['chapter_uid'])!=metadata['chapter_without_hash']:return False,None
    if metadata['operation'] in DELETING or metadata['operation']=='style':return rows_hash(marks['updated'])==metadata['after_hash'],None
    bookmark=metadata['operation']=='bookmark_create'
    chosen=[r['bookmarkId'] for r in marks['updated'] if (not bookmark or
            (r.get('style') is None or type(r['style']) is int and r['style']==0)
            and (r.get('colorStyle') is None or type(r['colorStyle']) is int and r['colorStyle']==0)
            and (r.get('markText') in (None,'') or digest([r['markText']])==metadata['reference_hash']))
            and fields_hash(r,POINT_MATCH if bookmark else MATCH)==metadata['match_hash']
            and rows_hash(marks['updated'],r['bookmarkId'])==metadata['before_hash']]
    return (True,chosen[0]) if len(chosen)==1 else (False,None)
