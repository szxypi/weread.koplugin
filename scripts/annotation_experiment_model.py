"""Pure bindings for one new private thought, edit and removal; no I/O."""
import hashlib
import json
import re
from my_cloud_marks_model import identifier,integer,text,project as marks_project
from my_cloud_thoughts_model import complete as thoughts_project
from shelf_flags_contract import FIELDS,flag
from verify_finish_roundtrip import point

PROTOCOL='private-thought-create-edit-delete-v1'
PREFIX='KOReader 私密想法验证'
HASH_FIELDS={'context_sha256','thoughts_sha256','marks_sha256','position_sha256','shelf_sha256'}
PLAN_FIELDS={'protocol','owner','book_id','bookmark_id','nonce','review_count','mark_count'}|HASH_FIELDS


def fail(reason):raise ValueError('annotation_experiment_'+reason)

def canonical(value):return json.dumps(value,sort_keys=True,separators=(',',':'),allow_nan=False,ensure_ascii=False).encode()

def digest(value):return hashlib.sha256(canonical(value)).hexdigest()

def valid_key(value):return text(value,256,False) and not any(c.isspace() for c in value)

def validate_plan(value):
    if not isinstance(value,dict) or set(value)!=PLAN_FIELDS or value['protocol']!=PROTOCOL:fail('plan')
    if not identifier(value['owner']) or not identifier(value['book_id']) or not valid_key(value['bookmark_id']):fail('plan')
    if not isinstance(value['nonce'],str) or not re.fullmatch('[a-f0-9]{32}',value['nonce']):fail('plan')
    if not integer(value['review_count'],18) or not integer(value['mark_count'],5000) or value['mark_count']==0:fail('plan')
    if any(not isinstance(value[key],str) or not re.fullmatch('[a-f0-9]{64}',value[key]) for key in HASH_FIELDS):fail('plan')
    return value

def fingerprint(value):return digest(validate_plan(value))

def note_text(nonce,edited=False):
    if not isinstance(nonce,str) or not re.fullmatch('[a-f0-9]{32}',nonce):fail('nonce')
    return f'{PREFIX} {nonce} '+('修改后' if edited else '初始内容')

def shelf_state(source):
    rows=source.get('books') if isinstance(source,dict) else None
    if not isinstance(rows,list) or len(rows)>5000:fail('shelf')
    result={}
    for row in rows:
        if not isinstance(row,dict):fail('shelf')
        key=str(row.get('bookId'))
        if not re.fullmatch('[A-Za-z0-9][A-Za-z0-9_-]{0,127}',key) or key in result:fail('shelf')
        result[key]={name:flag(row,field) for name,field in FIELDS.items()}
    return result

def thoughts_state(source,identity,owner):
    value=thoughts_project(source,identity,owner,1)
    return {row['reviewId']:row for row in value['reviews']}

def marks_state(source,identity,owner):
    value=marks_project(source,identity,owner,1)
    return dict(updated={row['bookmarkId']:row for row in value['updated']},
                chapters={str(row['chapterUid']):row for row in value['chapters']})

def context(source,info,identity,owner,bookmark_id=None):
    rows=marks_state(source,identity,owner)['updated']
    if not isinstance(info,dict) or str(info.get('bookId'))!=identity:fail('metadata')
    version=info.get('bookVersion',info.get('version'))
    if not integer(version,2147483647) or version==0:fail('version')
    choices=[]
    for key,row in rows.items():
        marker=row.get('range');match=re.fullmatch(r'([0-9]{1,10})-([0-9]{1,10})',marker or '')
        if (row.get('type')==1 and integer(row.get('chapterUid'),2147483647) and row['chapterUid']>0
                and text(row.get('markText'),4096,False) and match
                and 0<=int(match[1])<int(match[2])<=2147483647):choices.append(key)
    chosen=bookmark_id if bookmark_id is not None else min(choices,default=None)
    if chosen not in choices:fail('mark_unavailable')
    row=rows[chosen]
    result=dict(bookId=identity,chapterUid=str(row['chapterUid']),bookVersion=version,
                type=1,range=row['range'],abstract=row['markText'],isPrivate=1)
    if row.get('chapterIdx') is not None:result['chapterIdx']=row['chapterIdx']
    return chosen,result

def validate_context(ctx,identity):
    fields={'bookId','chapterUid','bookVersion','type','range','abstract','isPrivate'}
    if not isinstance(ctx,dict) or set(ctx) not in (fields,fields|{'chapterIdx'}) or ctx['bookId']!=identity:fail('context')
    if not identifier(ctx['chapterUid']) or int(ctx['chapterUid'])>2147483647:fail('context')
    if type(ctx['type']) is not int or ctx['type']!=1 or type(ctx['isPrivate']) is not int or ctx['isPrivate']!=1:fail('context')
    if not integer(ctx['bookVersion'],2147483647) or not ctx['bookVersion'] or not text(ctx['abstract'],4096,False):fail('context')
    match=re.fullmatch(r'([0-9]{1,10})-([0-9]{1,10})',ctx.get('range',''))
    if not match or not 0<=int(match[1])<int(match[2])<=2147483647:fail('context')
    if 'chapterIdx' in ctx and not integer(ctx['chapterIdx'],2147483647):fail('context')
    return ctx


def bind(owner,identity,bookmark_id,nonce,ctx,observed):
    validate_context(ctx,identity)
    value=dict(protocol=PROTOCOL,owner=owner,book_id=identity,bookmark_id=bookmark_id,nonce=nonce,
               review_count=len(observed['thoughts']),mark_count=len(observed['marks']['updated']),context_sha256=digest(ctx))
    for field in ('thoughts','marks','position','shelf'):value[field+'_sha256']=digest(observed[field])
    return validate_plan(value)

def expected_new(row,ctx,nonce,edited=False):
    return (isinstance(row,dict) and row.get('content')==note_text(nonce,edited)
            and row.get('isPrivate')==1 and type(row.get('isPrivate')) is int and row.get('type')==1
            and str(row.get('chapterUid'))==ctx['chapterUid'] and row.get('range')==ctx['range']
            and row.get('abstract')==ctx['abstract']
            and ('chapterIdx' not in ctx or row.get('chapterIdx')==ctx['chapterIdx']))
