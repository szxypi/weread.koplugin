"""Bindings for one native add/remove trial; no transport or write authority."""
from copy import deepcopy
import hashlib
import re
from secure_shelf_experiment import validate_plan as membership_plan,canonical
from verify_owner_shelf_membership import members_digest
from verify_eink_shelf_write import snapshot
from finish_change_contract import flags,flags_hash
from shelf_groups_contract import project as groups
from web_shelf_contract import normalize

PROTOCOL='native-shelf-add-remove-host-readback-v1'


def digest(value):return hashlib.sha256(canonical(value)).hexdigest()


def group_hash(source,identity):
    value=normalize(source)
    value['books']=[row for row in value['books'] if str(row['bookId'])!=identity]
    for row in value.get('archive',[]):
        row['bookIds']=[key for key in row.get('bookIds',[]) if str(key)!=identity]
    result=groups(value)
    for row in result:row['members'].sort()
    return digest(sorted(result,key=lambda row:row['key']))


def validate_plan(value):
    if (not isinstance(value,dict) or set(value)!={'protocol','membership','flags_sha256','groups_sha256'}
            or value['protocol']!=PROTOCOL):raise ValueError('native_shelf/plan')
    membership_plan(value['membership'])
    if any(not isinstance(value[key],str) or not re.fullmatch('[a-f0-9]{64}',value[key])
           for key in ('flags_sha256','groups_sha256')):raise ValueError('native_shelf/plan')
    return value


def bind(membership,source):
    membership_plan(membership);protected=flags(source);rows=snapshot(source)
    if (membership['book_id'] in rows or members_digest(rows)!=membership['members_sha256']
            or any(field.get('reason')=='invalid' for row in protected.values() for field in row.values())):
        raise ValueError('native_shelf/baseline')
    return validate_plan(dict(protocol=PROTOCOL,membership=deepcopy(membership),flags_sha256=flags_hash(protected),
                              groups_sha256=group_hash(source,membership['book_id'])))


def check(plan,source,present):
    validate_plan(plan)
    if type(present) is not bool:raise ValueError('native_shelf/presence')
    identity=plan['membership']['book_id'];protected=flags(source);rows=snapshot(source)
    if (identity in rows) is not present:raise ValueError('native_shelf/presence')
    rows.pop(identity,None);protected.pop(identity,None)
    if (members_digest(rows)!=plan['membership']['members_sha256'] or flags_hash(protected)!=plan['flags_sha256']
            or group_hash(source,identity)!=plan['groups_sha256']):raise ValueError('native_shelf/unrelated_change')
    return True
