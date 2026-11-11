"""Independent highlight postconditions; no transport or account persistence."""
from copy import deepcopy
from thought_edit_contract import digest,snapshot_hash as thoughts_hash
from highlight_trial_model import request

ROW=('bookmarkId','markText','abstract','range','chapterUid','chapterIdx','type','style','colorStyle','createTime')
MATCH=('markText','range','chapterUid','type','style','colorStyle')


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


def disjoint(rows,reference):
    a,b=map(int,reference['range'].split('-'))
    if not 0<=a<b<=2147483647:return False
    for row in rows:
        if row.get('chapterUid')!=reference['chapterUid']:continue
        try:first,last=map(int,row['range'].split('-'))
        except (KeyError,ValueError,AttributeError):return False
        if not 0<=first<last<=2147483647 or first<b and last>a:return False
    return True


def make(snapshot,operation,reference,metadata=None):
    book=snapshot['book_id'];marks=snapshot['marks'];notes=snapshot['thoughts']
    if operation=='create':
        if not reference.get('selection') or not disjoint(marks['updated'],reference):raise ValueError('mark_edit/selection')
        if str(metadata['bookId'])!=book:raise ValueError('mark_edit/metadata')
        row=reference;body=request(dict(bookId=book,chapterUid=row['chapterUid'],bookVersion=metadata.get('bookVersion',metadata.get('version')),range=row['range'],abstract=row['markText']))
    elif operation=='delete':
        row=next((r for r in marks['updated'] if r['bookmarkId']==reference['bookmarkId']),None)
        if row is None or row.get('type')!=1 or row_hash(row)!=row_hash(reference):raise ValueError('mark_edit/changed')
        body=dict(bookmarkIds=[row['bookmarkId']])
    else:raise ValueError('mark_edit/operation')
    if not disjoint(notes['reviews'],row):raise ValueError('mark_edit/linked_thought')
    uid=str(row['chapterUid'])
    return dict(snapshot=deepcopy(snapshot),body=body,metadata=dict(book_id=book,operation=operation,target_id=row['bookmarkId'],
        before_hash=rows_hash(marks['updated']),after_hash=rows_hash(marks['updated'],row['bookmarkId']) if operation=='delete' else '',
        reference_hash=row_hash(row),match_hash=fields_hash(body,MATCH) if operation=='create' else '',request_hash=body_hash(body),
        thoughts_hash=thoughts_hash(notes),chapters_hash=chapters_hash(marks['chapters']),
        chapter_without_hash=chapters_hash(marks['chapters'],uid),chapter_uid=uid,
        chapter_present=int(any(str(r['chapterUid'])==uid for r in marks['chapters']))))


def check(snapshot,metadata):
    if snapshot['book_id']!=metadata['book_id']:raise ValueError('mark_edit/book')
    marks=snapshot['marks']
    if thoughts_hash(snapshot['thoughts'])!=metadata['thoughts_hash']:return False,None
    if metadata['operation']=='delete' or metadata['chapter_present']:
        if chapters_hash(marks['chapters'])!=metadata['chapters_hash']:return False,None
    elif chapters_hash(marks['chapters'],metadata['chapter_uid'])!=metadata['chapter_without_hash']:return False,None
    if metadata['operation']=='delete':return rows_hash(marks['updated'])==metadata['after_hash'],None
    chosen=[r['bookmarkId'] for r in marks['updated'] if fields_hash(r,MATCH)==metadata['match_hash']
            and rows_hash(marks['updated'],r['bookmarkId'])==metadata['before_hash']]
    return (True,chosen[0]) if len(chosen)==1 else (False,None)
