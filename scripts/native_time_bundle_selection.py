"""Bind a native queue selection to the exact immutable capture bundle."""
from copy import deepcopy
import hashlib
import math

from native_time_capture_evidence import validate_evidence
from verify_native_position_lua import equivalent


def _encode(value,depth=0):
    if depth>=16:raise ValueError('bundle_selection/depth')
    if isinstance(value,str):
        data=value.encode('utf-8');return b's'+str(len(data)).encode()+b':'+data
    if type(value) is bool:return b't;' if value else b'f;'
    if type(value) in (int,float):
        if not math.isfinite(value) or abs(value)>2**53:raise ValueError('bundle_selection/number')
        return b'n'+('0' if value==0 else format(value,'.17g')).encode()+b';'
    if isinstance(value,list):
        if not value:return b'm0:'
        return b'a'+str(len(value)).encode()+b':'+b''.join(_encode(v,depth+1) for v in value)
    if isinstance(value,dict) and all(type(k) is str for k in value):
        keys=sorted(value,key=lambda k:k.encode('utf-8'))
        return b'm'+str(len(keys)).encode()+b':'+b''.join(_encode(k,depth+1)+_encode(value[k],depth+1) for k in keys)
    raise ValueError('bundle_selection/value')


def native_digest(value):return hashlib.sha256(_encode(value)).hexdigest()


def expected(bundle):
    if not isinstance(bundle,dict) or set(bundle)!={'plan','evidence'}:raise ValueError('bundle_selection/bundle')
    p=bundle['plan'];validate_evidence(p,bundle['evidence'])
    rows=deepcopy(p['rows'])
    parts=[dict(row_id=r['id'],start_time=r['start_time'],duration=r['duration']) for r in rows]
    protocol=[{k:r[k] for k in ('start_time','duration','time_zone','book_version')} for r in rows]
    return dict(book_id=p['book_id'],file_id=p['file_id'],book_version=p['book_version'],time_zone='+08:00',
                seconds=p['seconds'],rows=rows,parts=parts,protocol_rows=protocol,
                rows_hash=native_digest(rows),parts_hash=native_digest(parts))


def validate_selection(bundle,selection):
    if not equivalent(expected(bundle),selection):raise ValueError('bundle_selection/mismatch')
    return selection
