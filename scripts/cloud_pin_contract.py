"""Independent pinned-state model; missing is distinct from explicit false."""
from copy import deepcopy
import re
from finish_change_contract import flags,position_hash
from shelf_flag_change_contract import position,state_hash
from thought_edit_contract import digest


def request(identity,desired):
    if not isinstance(identity,str) or not re.fullmatch('[1-9][0-9]{0,19}',identity) or type(desired) is not bool:
        raise ValueError('cloud_pin/target')
    return dict(bookIds=[identity],albumIds=[],archiveIds=[],isDel=0 if desired else 1)


def request_hash(identity,desired):
    body=request(identity,desired)
    return digest(['shelf-flag-request-v1','pinned',identity,body['isDel']])


def make(source,progress,identity,desired):
    body=request(identity,desired);snapshot=flags(source);row=snapshot.get(identity)
    if not row or row['pinned'].get('reason')=='invalid':raise ValueError('cloud_pin/unknown')
    before=row['pinned'].get('value','missing')
    if type(before) is not bool and before!='missing' or not desired and before is not True:raise ValueError('cloud_pin/unknown')
    if any(field.get('reason')=='invalid' for item in snapshot.values() for field in item.values()):raise ValueError('cloud_pin/invalid')
    expected=deepcopy(source);target=next(row for row in expected['books'] if str(row['bookId'])==identity)
    target['isTop']=int(desired);after=state_hash(expected);alternate=after
    if not desired:
        del target['isTop'];alternate=state_hash(expected)
    return dict(metadata=dict(kind='pinned',book_id=identity,before=before,desired=desired,
        before_hash=state_hash(source),after_hash=after,alternate_hash=alternate,
        position_hash=position_hash(position(progress,identity)),request_hash=request_hash(identity,desired)),body=body)
