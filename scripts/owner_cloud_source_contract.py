"""Closed read-only cloud choice proof; original positions stay in private pipes."""
import hashlib
import json
import re
from verify_owner_reading import FRAME,validate_cookies,validate_stage as reading_stage
from secure_native_txt_roundtrip import point
from owner_source_candidate_contract import SOURCE_FIELDS
from txt_coordinates import PlainSource

FLAGS={'local_intent_created','cloud_choice','background_worker','raw_target','sync_verified','pending_cleared',
       'checkpoint_saved','truthful_notice','parent_native_guard','offline_checkpoint','offline_local_only'}


def validate_payload(value,mock_port=None):
    fields={'book_id','chapter_uid','source_text','shelf_ids','shelf_books','source_format','source_raw_sha256','source_sample_offset',
            'vid','cookies','native_source_excerpt','raw_cloud_preview'}
    if mock_port is not None:fields.add('cloud_mock_port')
    if not isinstance(value,dict) or set(value)!=fields:raise ValueError('cloud_choice/input')
    trial=value['raw_cloud_preview']
    if not isinstance(trial,dict) or set(trial)!={'baseline','target'}:raise ValueError('cloud_choice/input')
    point(trial['baseline']);point(trial['target']);validate_cookies(value['cookies'],value['vid'])
    if (value['book_id']!=trial['baseline']['book_id'] or value['chapter_uid']!=trial['baseline']['chapter_uid']
            or any(trial['baseline'][k]!=trial['target'][k] for k in ('book_id','chapter_uid','chapter_idx'))
            or trial['target']['chapter_offset']!=trial['baseline']['chapter_offset']+1 or value['source_format']!='web_txt'
            or value['native_source_excerpt'] is not True or not isinstance(value['source_raw_sha256'],str) or not re.fullmatch('[a-f0-9]{64}',value['source_raw_sha256'])
            or not isinstance(value['source_text'],str) or not 32<=len(value['source_text'].encode())<=128
            or type(value['source_sample_offset']) is not int or not 0<=value['source_sample_offset']<=16*1024*1024
            or type(value['shelf_books']) is not int or not 1<=value['shelf_books']<=5000
            or not isinstance(value['shelf_ids'],list) or not 1<=len(value['shelf_ids'])<=5000 or value['book_id'] not in value['shelf_ids']
            or any(not isinstance(v,str) or not re.fullmatch(r'(?:[1-9][0-9]{0,19}|CB_[A-Za-z0-9]{1,64})',v) for v in value['shelf_ids'])
            or value.get('cloud_mock_port')!=mock_port):raise ValueError('cloud_choice/input')
    if mock_port is not None and (type(mock_port) is not int or not 1<=mock_port<=65535 or value['vid']!='900000'
            or value['book_id']!='900001' or value['cookies']!={'wr_vid':'900000','wr_skey':'mock_key'}):raise ValueError('cloud_choice/mock')
    return value


def validate_source(value):
    if (not isinstance(value,dict) or set(value)!=SOURCE_FIELDS or value['basis']!='raw_txt_utf16' or value['upload_verified'] is not False
            or any(not isinstance(value[k],str) or not re.fullmatch('[1-9][0-9]{0,31}',value[k]) for k in ('book_id','chapter_uid'))
            or any(type(value[k]) is not int or not 0<=value[k]<=2147483647 for k in ('chapter_offset','book_version'))
            or any(not isinstance(value[k],str) or not re.fullmatch('[a-f0-9]{64}',value[k]) for k in ('file_id','raw_sha256'))
            or value['render_path']!='OEBPS/text/chapter.xhtml'):raise ValueError('cloud_choice/private')


def decode(raw,owner,mode):
    if mode not in ('live','reopen') or not isinstance(raw,bytes) or len(raw)>2*1024*1024 or raw.count(FRAME)!=1:raise ValueError('cloud_choice/frame')
    value=json.loads(raw.split(FRAME)[1])
    if not isinstance(value,dict) or not {'report','cookies'}<=set(value)<= {'report','cookies','candidate_private'}:raise ValueError('cloud_choice/envelope')
    validate_cookies(value['cookies'],owner);stage=value['report']
    if not isinstance(stage,dict):raise ValueError('cloud_choice/stage')
    a=stage.get('cloud_source')
    if (not isinstance(a,dict) or set(a)!=FLAGS|{'native_denied','failed_line'} or any(type(a[k]) is not bool for k in FLAGS)
            or any(type(a[k]) is not int or not 0<=a[k]<=cap for k,cap in (('native_denied',32),('failed_line',10000)))):
        raise ValueError('cloud_choice/stage')
    reading_stage({k:v for k,v in stage.items() if k!='cloud_source'},mode,selection_preview=True)
    if stage['result']=='PASS':
        required={'raw_target','parent_native_guard'}|({'offline_checkpoint','offline_local_only'} if mode=='reopen' else FLAGS-{'offline_checkpoint','offline_local_only'})
        if a['native_denied'] or a['failed_line'] or any(a[k]!=(k in required) for k in FLAGS):raise ValueError('cloud_choice/incomplete')
        private=value.get('candidate_private')
        if not isinstance(private,dict) or set(private)!={'position','checkpoint'}:raise ValueError('cloud_choice/private')
        for item in private.values():validate_source(item)
    return value


def compare(records,payload,raw):
    if not isinstance(records,list) or len(records)!=2:raise ValueError('cloud_choice/comparison')
    expected=payload['raw_cloud_preview']['baseline'];sha=hashlib.sha256(raw.encode()).hexdigest()
    if sha!=payload['source_raw_sha256']:raise ValueError('cloud_choice/source')
    PlainSource(raw).excerpt(expected['chapter_offset'])
    for record in records:
        if not isinstance(record,dict) or set(record)!={'position','checkpoint'}:raise ValueError('cloud_choice/comparison')
        for item in record.values():
            validate_source(item)
            if (item['book_id']!=expected['book_id'] or item['chapter_uid']!=expected['chapter_uid']
                    or item['chapter_offset']!=expected['chapter_offset'] or item['raw_sha256']!=sha):raise ValueError('cloud_choice/point')
    if records[0]!=records[1]:raise ValueError('cloud_choice/offline_changed')


def decode_runner(raw,owner):
    if not isinstance(raw,bytes) or len(raw)>4*1024*1024 or raw.count(FRAME)!=1:raise ValueError('cloud_choice/frame')
    value=json.loads(raw.split(FRAME)[1])
    if not isinstance(value,dict) or set(value)!={'report','cookies','candidate_private'}:raise ValueError('cloud_choice/envelope')
    report=value['report'];validate_cookies(value['cookies'],owner)
    if (not isinstance(report,dict) or set(report)!={'result','profile_removed','stages','installed','error'}
            or report['result'] not in ('PASS','UNVERIFIED') or type(report['profile_removed']) is not bool
            or report['error'] not in ('none','runner','cloud_choice/input','cloud_choice/runtime','cloud_choice/stage','cloud_choice/incomplete',
                                      'cloud_choice/private','cloud_choice/frame','cloud_choice/envelope','cloud_choice/mock')
            or not isinstance(report['stages'],list) or len(report['stages'])>2 or not isinstance(value['candidate_private'],list)
            or len(value['candidate_private'])!=len(report['stages'])):raise ValueError('cloud_choice/report')
    for index,(stage,private) in enumerate(zip(report['stages'],value['candidate_private'])):
        decode(FRAME+json.dumps(dict(report=stage,cookies=value['cookies'],candidate_private=private)).encode(),owner,('live','reopen')[index])
    if report['result']=='PASS':
        package=report['installed']
        if (len(report['stages'])!=2 or not report['profile_removed'] or report['error']!='none' or any(v['result']!='PASS' for v in report['stages'])
                or not isinstance(package,dict) or set(package)!={'files','bytes_match'} or type(package['files']) is not int
                or not 1<=package['files']<=1000 or package['bytes_match'] is not True):raise ValueError('cloud_choice/report')
    return value
