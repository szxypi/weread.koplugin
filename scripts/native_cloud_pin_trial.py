"""Bind two native pin operations to one shelf, owner and exact position."""
from copy import deepcopy
import re
from cloud_pin_contract import make,valid_metadata
from finish_change_contract import position_hash
from shelf_flag_change_contract import groups_hash,position,state_hash

PROTOCOL='native-cloud-pin-roundtrip-v1'


def validate_plan(value):
    if (not isinstance(value,dict) or set(value)!={'protocol','owner','book_id','grant_sha256','groups_sha256','mark','restore'}
            or value['protocol']!=PROTOCOL):raise ValueError('native_cloud_pin/plan')
    for key in ('owner','book_id'):
        if not isinstance(value[key],str) or not re.fullmatch('[1-9][0-9]{0,19}',value[key]):raise ValueError('native_cloud_pin/plan')
    for key in ('grant_sha256','groups_sha256'):
        if not isinstance(value[key],str) or not re.fullmatch('[a-f0-9]{64}',value[key]):raise ValueError('native_cloud_pin/plan')
    mark,restore=value['mark'],value['restore']
    if (not valid_metadata(mark) or not valid_metadata(restore) or mark['book_id']!=value['book_id']
            or restore['book_id']!=value['book_id'] or mark['desired'] is not True or restore['desired'] is not False
            or mark['before'] not in ('missing',False) or restore['before'] is not True
            or mark['after_hash']!=restore['before_hash'] or mark['before_hash'] not in (restore['after_hash'],restore['alternate_hash'])
            or mark['before_hash']==mark['after_hash'] or mark['position_hash']!=restore['position_hash']):
        raise ValueError('native_cloud_pin/plan')
    return value


def bind(owner,identity,grant_sha256,shelf,progress):
    mark=make(shelf,progress,identity,True);expected=deepcopy(shelf)
    next(row for row in expected['books'] if str(row['bookId'])==identity)['isTop']=1
    restore=make(expected,progress,identity,False)
    return validate_plan(dict(protocol=PROTOCOL,owner=owner,book_id=identity,grant_sha256=grant_sha256,
                              groups_sha256=groups_hash(shelf),mark=mark['metadata'],restore=restore['metadata']))


def check(plan,shelf,progress,pinned):
    validate_plan(plan)
    if type(pinned) is not bool:raise ValueError('native_cloud_pin/state')
    metadata=plan['mark' if pinned else 'restore'];actual=state_hash(shelf)
    if (actual not in ({metadata['after_hash']} if pinned else {metadata['after_hash'],metadata['alternate_hash']})
            or groups_hash(shelf)!=plan['groups_sha256']
            or position_hash(position(progress,plan['book_id']))!=metadata['position_hash']):
        raise ValueError('native_cloud_pin/changed')
    return True
