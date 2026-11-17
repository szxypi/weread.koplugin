"""Bounded exact HTTP receipts for one-shot translation operations. No I/O."""
import base64,json
from annotation_experiment_model import canonical

MAX_WIRE=8*1024


def pairs(items):
    value={}
    for key,item in items:
        if key in value:raise ValueError('duplicate JSON key')
        value[key]=item
    return value


def response(wire):
    if (not isinstance(wire,dict) or set(wire)!={'http_status','body_base64','body_truncated'}
            or type(wire['http_status']) is not int or not 100<=wire['http_status']<=599
            or not isinstance(wire['body_base64'],str) or len(wire['body_base64'])>4*((MAX_WIRE+2)//3)
            or type(wire['body_truncated']) is not bool):raise ValueError('translation_wire/shape')
    raw=base64.b64decode(wire['body_base64'],validate=True)
    if (len(raw)>MAX_WIRE or base64.b64encode(raw).decode()!=wire['body_base64']
            or wire['body_truncated'] and len(raw)!=MAX_WIRE):raise ValueError('translation_wire/size')
    if wire['body_truncated']:return {}
    try:
        value=json.loads(raw.decode('utf-8'),object_pairs_hook=pairs,parse_constant=lambda _:(_ for _ in ()).throw(ValueError()))
        canonical(value)
    except (ValueError,UnicodeError,RecursionError):return {}
    return value if isinstance(value,dict) else {}


def capture(http_status,raw):
    if not isinstance(raw,bytes) or len(raw)>MAX_WIRE+1:raise ValueError('translation_wire/size')
    value=dict(http_status=http_status,body_base64=base64.b64encode(raw[:MAX_WIRE]).decode(),body_truncated=len(raw)>MAX_WIRE)
    response(value);return value


def successful_http(wire):
    response(wire)
    return wire['http_status']==200 and not wire['body_truncated']
