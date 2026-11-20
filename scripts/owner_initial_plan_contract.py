"""Closed read-only initialization candidate proof; grants are not accepted."""
from copy import deepcopy
import json
from owner_unstarted_contract import validate_payload as common_payload
from verify_owner_reading import FRAME,validate_cookies,validate_stage as reading_stage
from owner_cloud_source_contract import validate_source
from secure_native_txt_roundtrip import point,POINT_FIELDS
from source_remote_position import catalog_index
from txt_coordinates import PlainSource

FLAGS={'visible_point','local_only','background_worker','currentness_verified','integer_percent','parent_native_guard'}


def validate_payload(v,mock_port=None):
    if not isinstance(v,dict) or v.get('initial_plan_preview') is not True:raise ValueError('initial_plan/input')
    selected=deepcopy(v);selected['unstarted_preview']=selected.pop('initial_plan_preview')
    if mock_port is not None:selected['unstarted_mock_port']=selected.pop('initial_plan_mock_port',None)
    common_payload(selected,mock_port);return v


def validate_private(v,payload=None,raw=None,chapters=None):
    if not isinstance(v,dict) or set(v)!={'source','candidate'}:raise ValueError('initial_plan/private')
    validate_source(v['source']);point(v['candidate']);p,c=v['source'],v['candidate']
    if any(str(p[k])!=str(c[k]) for k in ('book_id','chapter_uid','chapter_offset')):raise ValueError('initial_plan/private')
    if type(c['raw_percent']) is not int or len(c['summary'])!=30:raise ValueError('initial_plan/private')
    if payload is not None and (p['book_id']!=payload['book_id'] or p['chapter_uid']!=payload['chapter_uid'] or p['raw_sha256']!=payload['source_raw_sha256']):raise ValueError('initial_plan/binding')
    if raw is not None and PlainSource(raw).excerpt(c['chapter_offset'])['text']!=c['summary']:raise ValueError('initial_plan/excerpt')
    if chapters is not None and catalog_index(chapters,c['chapter_uid'])!=c['chapter_idx']:raise ValueError('initial_plan/index')
    return {k:c[k] for k in POINT_FIELDS}


def decode(raw,owner):
    if not isinstance(raw,bytes) or len(raw)>2*1024*1024 or raw.count(FRAME)!=1:raise ValueError('initial_plan/frame')
    v=json.loads(raw.split(FRAME)[1])
    if not isinstance(v,dict) or not {'report','cookies'}<=set(v)<={'report','cookies','candidate_private'}:raise ValueError('initial_plan/frame')
    validate_cookies(v['cookies'],owner);stage=v['report'];a=stage.get('initial_plan') if isinstance(stage,dict) else None
    if not isinstance(a,dict) or set(a)!=FLAGS|{'native_denied','failed_line'} or any(type(a[k]) is not bool for k in FLAGS) or any(type(a[k]) is not int or not 0<=a[k]<=cap for k,cap in (('native_denied',32),('failed_line',10000))):raise ValueError('initial_plan/stage')
    reading_stage({k:x for k,x in stage.items() if k!='initial_plan'},'live',selection_preview=True)
    if stage['result']=='PASS':
        if not all(a[k] for k in FLAGS) or a['native_denied'] or a['failed_line']:raise ValueError('initial_plan/incomplete')
        validate_private(v.get('candidate_private'))
    return v


def decode_runner(raw,owner):
    if not isinstance(raw,bytes) or len(raw)>4*1024*1024 or raw.count(FRAME)!=1:raise ValueError('initial_plan/frame')
    v=json.loads(raw.split(FRAME)[1]);r=v.get('report') if isinstance(v,dict) else None
    if (not isinstance(v,dict) or set(v)!={'report','cookies','candidate_private'} or not isinstance(r,dict)
            or set(r)!={'result','profile_removed','stages','installed','error'} or r['result'] not in ('PASS','UNVERIFIED')
            or type(r['profile_removed']) is not bool or not isinstance(r['stages'],list) or len(r['stages'])>1
            or not isinstance(v['candidate_private'],list) or len(v['candidate_private'])!=len(r['stages'])):raise ValueError('initial_plan/frame')
    validate_cookies(v['cookies'],owner)
    for s,p in zip(r['stages'],v['candidate_private']):decode(FRAME+json.dumps(dict(report=s,cookies=v['cookies'],candidate_private=p)).encode(),owner)
    if r['result']=='PASS':
        i=r['installed']
        if not r['profile_removed'] or r['error']!='none' or len(r['stages'])!=1 or r['stages'][0]['result']!='PASS' or not isinstance(i,dict) or set(i)!={'files','bytes_match'} or type(i['files']) is not int or not 1<=i['files']<=1000 or i['bytes_match'] is not True:raise ValueError('initial_plan/incomplete')
    return v
