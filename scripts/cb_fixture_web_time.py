"""Exact two-second Web request for one preverified self-authored CB fixture.

Pure construction and validation only. There is no network client here.
"""
import hashlib
import time
from cb_fixture_position import LONG_SUMMARY,body as position_body,validate as validate_position
from fetch_weread_epub import sorted_query,weread_sign


def build(plan):
    value=position_body(plan,'same')
    value['rt']=2
    value['s']=weread_sign(sorted_query({k:v for k,v in value.items() if k!='s'}))
    validate(plan,value)
    return value


def validate(plan,value,*,now=None):
    now=int(time.time()) if now is None else now
    if not isinstance(value,dict) or type(value.get('rt')) is not int or value['rt']!=2:
        raise ValueError('cb_time/body')
    if value.get('sm')!=LONG_SUMMARY or value.get('s')!=weread_sign(sorted_query({k:v for k,v in value.items() if k!='s'})):
        raise ValueError('cb_time/body')
    if value.get('sg')!=hashlib.sha256(f"{value.get('ts')}{value.get('rn')}{plan['token']}".encode()).hexdigest():
        raise ValueError('cb_time/body')
    zero=dict(value,rt=0)
    zero['s']=weread_sign(sorted_query({k:v for k,v in zero.items() if k!='s'}))
    validate_position(plan,'same',zero,now=now)
    return True
