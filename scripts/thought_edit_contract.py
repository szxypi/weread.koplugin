"""Independent one-operation thought edits; stable digests never contain tokens.

Endpoints/payloads were verified by the authorized private-thought roundtrip.
These helpers model arbitrary user text without appending a test nonce.
"""
import hashlib
from copy import deepcopy
from annotation_experiment_model import context as mark_context
from my_cloud_marks_model import identifier,integer,text

FIELDS=('reviewId','content','abstract','chapterName','range','chapterUid','chapterIdx','type','createTime','isPrivate','isFinish')
MATCH=('type','chapterUid','range','abstract','isPrivate')


def packed(values):
    parts=[]
    for value in values:
        if value is None:parts.append(b'n;')
        elif type(value) is str:
            raw=value.encode();parts.append(b's'+str(len(raw)).encode()+b':'+raw)
        elif type(value) is int:parts.append(b'i'+str(value).encode()+b';')
        else:raise ValueError('thought_edit/scalar')
    return b''.join(parts)


def digest(values):return hashlib.sha256(packed(values)).hexdigest()


def row_hash(row):return digest(row.get(key) for key in FIELDS)


def snapshot_hash(snapshot):
    rows=snapshot['reviews'];keys=[row['reviewId'] for row in rows]
    if len(set(keys))!=len(keys):raise ValueError('thought_edit/duplicate')
    return digest(['thoughts-v1',len(rows)]+[row_hash(row) for row in sorted(rows,key=lambda row:row['reviewId'])])


def valid_content(value):return text(value,131072,False) and bool(value.strip())


def context_match(row,indexed=False):
    values=[int(row['chapterUid']) if key=='chapterUid' and str(row.get(key,'')).isdigit() else row.get(key) for key in MATCH]
    if indexed:values.append(row.get('chapterIdx'))
    return digest(values)


def make(snapshot,operation,reference,content=None,*,marks=None,metadata=None,owner=None):
    book=snapshot['book_id']
    if not identifier(book) or operation not in ('create','edit','delete'):raise ValueError('thought_edit/operation')
    if operation!='delete' and not valid_content(content):raise ValueError('thought_edit/content')
    before=snapshot_hash(snapshot);rows={row['reviewId']:row for row in snapshot['reviews']}
    if operation=='create':
        key,ctx=mark_context(marks,metadata,book,owner,reference['bookmarkId'])
        selected=next(row for row in marks['updated'] if row['bookmarkId']==key)
        for name in ('type','chapterUid','range','markText'):
            if reference.get(name)!=selected.get(name):raise ValueError('thought_edit/changed')
        body=dict(ctx,content=content);indexed='chapterIdx' in ctx
        match_hash=context_match(dict(ctx,chapterUid=int(ctx['chapterUid'])),indexed)
        target=key;after='';reference_hash=digest(reference.get(k) for k in ('bookmarkId','type','chapterUid','range','markText'))
    else:
        target=reference['reviewId'];row=rows.get(target)
        if row is None or row_hash(row)!=row_hash(reference):raise ValueError('thought_edit/changed')
        if row.get('isPrivate') not in (0,1):raise ValueError('thought_edit/privacy')
        body=dict(reviewId=target)
        changed=deepcopy(snapshot)
        if operation=='edit':
            body['content']=content
            for entry in changed['reviews']:
                if entry['reviewId']==target:entry['content']=content
        else:changed['reviews']=[entry for entry in changed['reviews'] if entry['reviewId']!=target]
        after=snapshot_hash(changed);reference_hash=row_hash(row);match_hash='';indexed=False
    body_keys=sorted(body)
    request_hash=digest(['body-v1']+[part for key in body_keys for part in (key,body[key])])
    public=dict(book_id=book,operation=operation,target_id=target,before_hash=before,after_hash=after,
        reference_hash=reference_hash,content_hash=digest([content]) if operation!='delete' else '',
        match_hash=match_hash,match_index=int(indexed),request_hash=request_hash)
    return dict(metadata=public,body=body,snapshot=snapshot)


def check(snapshot,metadata):
    if snapshot['book_id']!=metadata['book_id']:raise ValueError('thought_edit/book')
    if metadata['operation']!='create':return snapshot_hash(snapshot)==metadata['after_hash'],None
    candidates=[]
    for row in snapshot['reviews']:
        if (digest([row['content']])==metadata['content_hash'] and context_match(row,bool(metadata['match_index']))==metadata['match_hash']):
            other=dict(snapshot,reviews=[item for item in snapshot['reviews'] if item['reviewId']!=row['reviewId']])
            if snapshot_hash(other)==metadata['before_hash']:candidates.append(row['reviewId'])
    return len(candidates)==1,candidates[0] if len(candidates)==1 else None
