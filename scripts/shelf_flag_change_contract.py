"""Single observable shelf-flag changes. No I/O or implicit missing=false."""
from copy import deepcopy
import re
from finish_change_contract import flags,flags_hash,position_hash
from thought_edit_contract import digest
from verify_finish_roundtrip import point
from my_cloud_marks_model import identifier

FIELDS={'private':'secret','pinned':'isTop'}


def groups_hash(source):
    rows=source.get('archive',[]) if isinstance(source,dict) else None
    if not isinstance(rows,list) or len(rows)>10000:raise ValueError('shelf_flag/groups')
    groups=[];seen=set()
    for row in rows:
        if not isinstance(row,dict) or not isinstance(row.get('name',''),str):raise ValueError('shelf_flag/groups')
        key=row.get('archiveId',row.get('id',''));key=str(key) if type(key) in (int,str) else ''
        name=row.get('name','')
        if (key,name) in seen:raise ValueError('shelf_flag/groups')
        seen.add((key,name));members=[]
        for field in ('bookIds','albumIds'):
            values=row.get(field,[])
            if not isinstance(values,list) or any(type(value) not in (str,int) or isinstance(value,int) and not 0<value<=9007199254740991 for value in values):raise ValueError('shelf_flag/groups')
            members.append(sorted(str(value) for value in values))
        pin=row.get('isTop');state='m' if 'isTop' not in row else '1' if pin is True or type(pin) in (int,float) and pin==1 else '0' if pin is False or type(pin) in (int,float) and pin==0 else 'i'
        if state=='i':raise ValueError('shelf_flag/groups')
        groups.append((key,name,members,state))
    parts=['shelf-flag-groups-v1',len(groups)]
    for key,name,members,pin in sorted(groups):
        parts.extend([key,name,pin])
        for values in members:parts.extend([len(values),*values])
    return digest(parts)


def state_hash(source):return digest(['shelf-flag-state-v1',flags_hash(flags(source)),groups_hash(source)])


def request(kind,identity,desired):
    if kind not in FIELDS or not identifier(identity) or type(desired) is not bool:raise ValueError('shelf_flag/target')
    if kind=='private':return dict(bookIds=[identity],private=1 if desired else 0)
    return dict(bookIds=[identity],isDel=0 if desired else 1)


def request_hash(kind,identity,desired):
    request(kind,identity,desired)
    return digest(['shelf-flag-request-v1',kind,identity,int(desired)])


def position(progress,identity):
    value=point(progress,identity)
    if value['chapter_uid']=='0':
        if any(value[key]!=0 for key in ('chapter_idx','chapter_offset','percent')):raise ValueError('shelf_flag/position')
    elif not identifier(value['chapter_uid']):raise ValueError('shelf_flag/position')
    return value


def make(source,progress,identity,kind,desired):
    body=request(kind,identity,desired);snapshot=flags(source);row=snapshot.get(identity)
    before=row.get(kind,{}).get('value') if row else None
    if type(before) is not bool:raise ValueError('shelf_flag/unknown')
    if any(flag.get('reason')=='invalid' for item in snapshot.values() for flag in item.values()):raise ValueError('shelf_flag/invalid_flag')
    expected=deepcopy(source)
    next(row for row in expected['books'] if str(row['bookId'])==identity)[FIELDS[kind]]=int(desired)
    return dict(metadata=dict(kind=kind,book_id=identity,before=before,desired=desired,
        before_hash=state_hash(source),after_hash=state_hash(expected),position_hash=position_hash(position(progress,identity)),
        request_hash=request_hash(kind,identity,desired)),body=body)


def valid_metadata(value):
    fields={'kind','book_id','before','desired','before_hash','after_hash','position_hash','request_hash'}
    return (isinstance(value,dict) and set(value)==fields and isinstance(value['kind'],str) and value['kind'] in FIELDS and identifier(value['book_id'])
        and type(value['before']) is bool and type(value['desired']) is bool
        and all(isinstance(value[key],str) and re.fullmatch('[a-f0-9]{64}',value[key]) for key in fields-{'kind','book_id','before','desired'})
        and value['request_hash']==request_hash(value['kind'],value['book_id'],value['desired']))


def check(source,progress,metadata):
    if not valid_metadata(metadata):raise ValueError('shelf_flag/metadata')
    return state_hash(source)==metadata['after_hash'] and position_hash(position(progress,metadata['book_id']))==metadata['position_hash']
