"""One new native finished-mark test and its separately previewed restoration."""
from copy import deepcopy
import re
from finish_change_contract import make,request,check as check_change
from thought_edit_contract import digest
from native_shelf_trial import group_hash

PROTOCOL='native-single-finished-mark-restore-host-readback-v1'


def request_hash(identity,desired):
    body=request(identity,desired)
    return digest(['body-v1']+[v for key in sorted(body) for v in (key,body[key])])


def validate_plan(value):
    if (not isinstance(value,dict) or set(value)!={'protocol','owner','book_id','grant_sha256','groups_sha256','mark','restore'}
            or value['protocol']!=PROTOCOL):raise ValueError('native_finish/plan')
    for key in ('owner','book_id'):
        if not isinstance(value[key],str) or not re.fullmatch('[1-9][0-9]{0,19}',value[key]):raise ValueError('native_finish/plan')
    for key in ('grant_sha256','groups_sha256'):
        if not isinstance(value[key],str) or not re.fullmatch('[a-f0-9]{64}',value[key]):raise ValueError('native_finish/plan')
    for key,desired in (('mark',True),('restore',False)):
        row=value[key]
        if (not isinstance(row,dict) or set(row)!={'book_id','before','desired','before_hash','after_hash','position_hash','request_hash'}
                or row['book_id']!=value['book_id'] or row['before'] is not (not desired) or row['desired'] is not desired
                or any(not isinstance(row[field],str) or not re.fullmatch('[a-f0-9]{64}',row[field])
                       for field in ('before_hash','after_hash','position_hash','request_hash'))
                or row['request_hash']!=request_hash(value['book_id'],desired)):raise ValueError('native_finish/plan')
    a,b=value['mark'],value['restore']
    if (a['before_hash']==a['after_hash'] or a['before_hash']!=b['after_hash'] or a['after_hash']!=b['before_hash']
            or a['position_hash']!=b['position_hash']):
        raise ValueError('native_finish/plan')
    return value


def bind(owner,identity,grant_hash,shelf,progress):
    mark=make(shelf,progress,identity,True)
    if mark['metadata']['before'] is not False:raise ValueError('native_finish/before')
    expected=deepcopy(shelf)
    row=next(row for row in expected['books'] if str(row['bookId'])==identity);row['finishReading']=1
    restore=make(expected,progress,identity,False)
    return validate_plan(dict(protocol=PROTOCOL,owner=owner,book_id=identity,grant_sha256=grant_hash,
        groups_sha256=group_hash(shelf,None),mark=mark['metadata'],restore=restore['metadata']))


def check(plan,shelf,progress,finished):
    validate_plan(plan)
    if type(finished) is not bool:raise ValueError('native_finish/desired')
    metadata=plan['mark' if finished else 'restore']
    if not check_change(shelf,progress,metadata) or group_hash(shelf,None)!=plan['groups_sha256']:
        raise ValueError('native_finish/changed')
    return True
