"""Native private-reading roundtrip, distinct from the Python protocol trial."""
from copy import deepcopy
import re
from shelf_flag_change_contract import make,check as check_change,valid_metadata,groups_hash

PROTOCOL='native-single-private-reading-restore-host-readback-v1'


def validate_plan(value):
    if (not isinstance(value,dict) or set(value)!={'protocol','owner','book_id','grant_sha256','groups_sha256','mark','restore'}
            or value['protocol']!=PROTOCOL):raise ValueError('native_shelf_flag/plan')
    for key in ('owner','book_id'):
        if not isinstance(value[key],str) or not re.fullmatch('[1-9][0-9]{0,19}',value[key]):raise ValueError('native_shelf_flag/plan')
    for key in ('grant_sha256','groups_sha256'):
        if not isinstance(value[key],str) or not re.fullmatch('[a-f0-9]{64}',value[key]):raise ValueError('native_shelf_flag/plan')
    for key,desired in (('mark',True),('restore',False)):
        row=value[key]
        if (not valid_metadata(row) or row['kind']!='private' or row['book_id']!=value['book_id']
                or row['before'] is not (not desired) or row['desired'] is not desired):raise ValueError('native_shelf_flag/plan')
    a,b=value['mark'],value['restore']
    if (a['before_hash']==a['after_hash'] or a['before_hash']!=b['after_hash'] or a['after_hash']!=b['before_hash']
            or a['position_hash']!=b['position_hash']):raise ValueError('native_shelf_flag/plan')
    return value


def bind(owner,identity,grant_hash,shelf,progress):
    mark=make(shelf,progress,identity,'private',True)
    if mark['metadata']['before'] is not False:raise ValueError('native_shelf_flag/before')
    expected=deepcopy(shelf);next(row for row in expected['books'] if str(row['bookId'])==identity)['secret']=1
    restore=make(expected,progress,identity,'private',False)
    return validate_plan(dict(protocol=PROTOCOL,owner=owner,book_id=identity,grant_sha256=grant_hash,
        groups_sha256=groups_hash(shelf),mark=mark['metadata'],restore=restore['metadata']))


def check(plan,shelf,progress,private):
    validate_plan(plan)
    if type(private) is not bool:raise ValueError('native_shelf_flag/desired')
    if not check_change(shelf,progress,plan['mark' if private else 'restore']) or groups_hash(shelf)!=plan['groups_sha256']:
        raise ValueError('native_shelf_flag/changed')
    return True
