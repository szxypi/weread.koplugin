"""Single completion change planning; no I/O or receipt interpretation.

The request fields/effects were observed in the two separately authorized
mark/restore attempts. This model keeps those historical ACK failures intact.
Any future write requires one fresh confirmation and independent full readback;
it never licenses an automatic toggle, restoration or a second write.
"""
from copy import deepcopy
import re
from annotation_experiment_model import shelf_state
from thought_edit_contract import digest
from my_cloud_marks_model import identifier
from verify_finish_roundtrip import point

FIELDS=('pinned','private','finished')


def flags(source):
    rows=source.get('books') if isinstance(source,dict) else None
    if not isinstance(rows,list):raise ValueError('finish_change/shelf')
    for key in ('errcode','errCode'):
        if key in source and (type(source[key]) not in (int,float) or source[key]!=0):raise ValueError('finish_change/shelf')
    if 'succ' in source and not (source['succ'] is True or type(source['succ']) in (int,float) and source['succ']==1):raise ValueError('finish_change/shelf')
    # Require an actual scalar ID; Python's str(True)/str(None) are not IDs.
    for row in rows:
        identity=row.get('bookId') if isinstance(row,dict) else None
        if type(identity) is int and not 1<=identity<=9007199254740991:raise ValueError('finish_change/shelf')
        if type(identity) not in (str,int):raise ValueError('finish_change/shelf')
    return shelf_state(source)


def flags_hash(value):
    parts=['finish-flags-v1',len(value)]
    for identity in sorted(value):
        if not isinstance(identity,str) or not re.fullmatch('[A-Za-z0-9][A-Za-z0-9_-]{0,127}',identity):raise ValueError('finish_change/shelf')
        parts.append(identity)
        for field in FIELDS:
            flag=value[identity][field]
            parts.append('1' if flag=={'value':True} else '0' if flag=={'value':False} else 'm' if flag=={'reason':'missing'} else 'i')
    return digest(parts)


def position_hash(value):
    return digest(['finish-position-v1',value['chapter_uid'],value['chapter_idx'],value['chapter_offset'],format(value['percent'],'.17g')])


def request(identity,desired):
    if not identifier(identity) or type(desired) is not bool:raise ValueError('finish_change/target')
    return dict(bookId=identity,auto=0,finishInfo=0,isCancel=0 if desired else 1,status=4)


def make(source,progress,identity,desired):
    body=request(identity,desired);snapshot=flags(source);row=snapshot.get(identity)
    before=row['finished'].get('value') if row else None
    if type(before) is not bool:raise ValueError('finish_change/unknown')
    if any(flag.get('reason')=='invalid' for item in snapshot.values() for flag in item.values()):raise ValueError('finish_change/invalid_flag')
    position=point(progress,identity)
    if not identifier(position['chapter_uid']):raise ValueError('finish_change/position')
    expected=deepcopy(snapshot);expected[identity]['finished']={'value':desired}
    request_hash=digest(['body-v1']+[v for key in sorted(body) for v in (key,body[key])])
    metadata=dict(book_id=identity,before=before,desired=desired,before_hash=flags_hash(snapshot),after_hash=flags_hash(expected),
                  position_hash=position_hash(position),request_hash=request_hash)
    return dict(metadata=metadata,body=body)


def check(source,progress,metadata):
    """Exactly one expected flag transition, all members/other flags unchanged."""
    return flags_hash(flags(source))==metadata['after_hash'] and position_hash(point(progress,metadata['book_id']))==metadata['position_hash']
