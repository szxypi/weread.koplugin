"""Private component fingerprints for later shelf-difference diagnosis.

Only hashes and structural field names are retained. The full shelf projection
is not persisted, and a comparison never establishes account provenance.
"""
import re

from annotation_experiment_model import canonical,digest
from txt_full_summary import digest as projection_digest

MAX_BYTES=8192
KNOWN={'archiveId','name','bookIds','albumIds','isTop','removed','lectureBookIds','lectureRemoved','updateTime'}
HASH=re.compile(r'[a-f0-9]{64}\Z')


def make(projection):
    if (not isinstance(projection,dict) or set(projection)!={'members','flags','groups','albums'}
            or not isinstance(projection['members'],list) or not isinstance(projection['groups'],dict)
            or len(projection['groups'])>1000 or not isinstance(projection['flags'],str)
            or not HASH.fullmatch(projection['flags']) or not isinstance(projection['albums'],dict)):
        raise ValueError('shelf_components/projection')
    groups={}
    for identity,row in projection['groups'].items():
        if not isinstance(identity,str) or not isinstance(row,dict) or len(row)>128:
            raise ValueError('shelf_components/projection')
        fields={}
        for key,value in row.items():
            if not isinstance(key,str) or not re.fullmatch(r'[A-Za-z][A-Za-z0-9_]{0,63}',key):
                return None
            label=key if key in KNOWN else 'other_'+digest(['shelf-component-field-name-v1',key])
            fields[label]=digest(['shelf-component-field-v1',value])
        groups[digest(['shelf-component-group-v1',identity])]=fields
    value=dict(protocol='shelf-components-v1',projection=projection_digest(projection),members=digest(projection['members']),
               flags=projection['flags'],albums=digest(projection['albums']),groups=groups)
    return value if len(canonical(value))<=MAX_BYTES else None


def validate(value,expected):
    if (not isinstance(value,dict) or set(value)!={'protocol','projection','members','flags','albums','groups'}
            or value['protocol']!='shelf-components-v1' or value['projection']!=expected
            or any(not isinstance(value[k],str) or not HASH.fullmatch(value[k]) for k in ('projection','members','flags','albums'))
            or not isinstance(value['groups'],dict) or len(value['groups'])>1000 or len(canonical(value))>MAX_BYTES):
        raise ValueError('shelf_components/record')
    for ident,fields in value['groups'].items():
        if (not isinstance(ident,str) or not HASH.fullmatch(ident) or not isinstance(fields,dict) or len(fields)>128
                or any(not isinstance(key,str) or not (key in KNOWN or re.fullmatch(r'other_[a-f0-9]{64}',key))
                       or not isinstance(mark,str) or not HASH.fullmatch(mark) for key,mark in fields.items())):
            raise ValueError('shelf_components/record')
    return value


def compare(before,after):
    """Return aggregate change categories only, with no book or group IDs."""
    validate(before,before.get('projection') if isinstance(before,dict) else None)
    validate(after,after.get('projection') if isinstance(after,dict) else None)
    left,right=before['groups'],after['groups'];known=set();other=False
    for ident in set(left)&set(right):
        for key in set(left[ident])|set(right[ident]):
            if left[ident].get(key)!=right[ident].get(key):
                if key in KNOWN:known.add(key)
                else:other=True
    return dict(members_changed=before['members']!=after['members'],flags_changed=before['flags']!=after['flags'],
                albums_changed=before['albums']!=after['albums'],groups_added_or_removed=set(left)!=set(right),
                group_fields_changed=sorted(known),other_group_fields_changed=other)
