"""Closed unstarted-book UI proof; no grant, write slot or summary allowed."""
import hashlib,json,re
from verify_owner_reading import FRAME,validate_cookies,validate_stage as reading_stage
from owner_cloud_source_contract import validate_source
from txt_coordinates import PlainSource

FLAGS={'local_intent','no_chapter_choice','cancelled_locally','unverified','timer_stopped','retry_kept','parent_native_guard','offline_local_only','initial_offline_checkpoint'}


def validate_payload(value,mock_port=None):
    fields={'book_id','chapter_uid','source_text','shelf_ids','shelf_books','source_format','source_raw_sha256','source_sample_offset',
            'vid','cookies','native_source_excerpt','unstarted_preview'}
    if mock_port is not None:fields.add('unstarted_mock_port')
    if not isinstance(value,dict) or set(value)!=fields:raise ValueError('unstarted/input')
    validate_cookies(value['cookies'],value['vid'])
    if (value['unstarted_preview'] is not True or value['native_source_excerpt'] is not True or value['source_format']!='web_txt'
            or any(not isinstance(value[k],str) or not re.fullmatch('[1-9][0-9]{0,19}',value[k]) for k in ('book_id','chapter_uid'))
            or not isinstance(value['source_raw_sha256'],str) or not re.fullmatch('[a-f0-9]{64}',value['source_raw_sha256'])
            or not isinstance(value['source_text'],str) or not 32<=len(value['source_text'].encode())<=128
            or type(value['source_sample_offset']) is not int or not 0<=value['source_sample_offset']<=16*1024*1024
            or type(value['shelf_books']) is not int or not 1<=value['shelf_books']<=5000
            or not isinstance(value['shelf_ids'],list) or not 1<=len(value['shelf_ids'])<=5000 or value['book_id'] not in value['shelf_ids']
            or any(not isinstance(v,str) or not re.fullmatch(r'(?:[1-9][0-9]{0,19}|CB_[A-Za-z0-9]{1,64})',v) for v in value['shelf_ids'])
            or value.get('unstarted_mock_port')!=mock_port):raise ValueError('unstarted/input')
    if mock_port is not None and (type(mock_port) is not int or not 1<=mock_port<=65535 or value['vid']!='900000'
            or value['book_id']!='900001' or value['cookies']!={'wr_vid':'900000','wr_skey':'mock_key'}):raise ValueError('unstarted/mock')
    return value


def decode(raw,owner,mode):
    if mode not in ('live','reopen') or not isinstance(raw,bytes) or len(raw)>2*1024*1024 or raw.count(FRAME)!=1:raise ValueError('unstarted/frame')
    v=json.loads(raw.split(FRAME)[1])
    if not isinstance(v,dict) or not {'report','cookies'}<=set(v)<= {'report','cookies','candidate_private'}:raise ValueError('unstarted/envelope')
    validate_cookies(v['cookies'],owner);stage=v['report'];a=stage.get('unstarted') if isinstance(stage,dict) else None
    if (not isinstance(a,dict) or set(a)!=FLAGS|{'native_denied','failed_line'} or any(type(a[k]) is not bool for k in FLAGS)
            or any(type(a[k]) is not int or not 0<=a[k]<=cap for k,cap in (('native_denied',32),('failed_line',10000)))):raise ValueError('unstarted/stage')
    reading_stage({k:x for k,x in stage.items() if k!='unstarted'},mode,selection_preview=True)
    if stage['result']=='PASS':
        required={'parent_native_guard','local_intent','unverified','timer_stopped'}|({'offline_local_only','initial_offline_checkpoint'} if mode=='reopen' else {'no_chapter_choice','cancelled_locally','retry_kept'})
        if a['native_denied'] or a['failed_line'] or any(a[k]!=(k in required) for k in FLAGS):raise ValueError('unstarted/incomplete')
        private=v.get('candidate_private')
        if not isinstance(private,dict) or set(private)!={'position','checkpoint'}:raise ValueError('unstarted/private')
        for value in private.values():validate_source(value)
    return v


def compare(records,payload,raw):
    if not isinstance(records,list) or len(records)!=2 or records[0]!=records[1]:raise ValueError('unstarted/offline_changed')
    sha=hashlib.sha256(raw.encode()).hexdigest()
    if sha!=payload['source_raw_sha256']:raise ValueError('unstarted/source')
    for record in records:
        if not isinstance(record,dict) or set(record)!={'position','checkpoint'}:raise ValueError('unstarted/private')
        for p in record.values():
            validate_source(p)
            if p['book_id']!=payload['book_id'] or p['chapter_uid']!=payload['chapter_uid'] or p['raw_sha256']!=sha:raise ValueError('unstarted/point')
            PlainSource(raw).excerpt(p['chapter_offset'])
        if record['position']!=record['checkpoint']:raise ValueError('unstarted/checkpoint')


def decode_runner(raw,owner):
    if not isinstance(raw,bytes) or len(raw)>4*1024*1024 or raw.count(FRAME)!=1:raise ValueError('unstarted/frame')
    v=json.loads(raw.split(FRAME)[1])
    if not isinstance(v,dict) or set(v)!={'report','cookies','candidate_private'}:raise ValueError('unstarted/envelope')
    r=v['report'];validate_cookies(v['cookies'],owner)
    if (not isinstance(r,dict) or set(r)!={'result','profile_removed','stages','installed','error'} or r['result'] not in ('PASS','UNVERIFIED')
            or type(r['profile_removed']) is not bool or not isinstance(r['stages'],list) or len(r['stages'])>2
            or not isinstance(r['error'],str) or not re.fullmatch(r'none|runner|unstarted/[a-z_]+',r['error'])
            or not isinstance(v['candidate_private'],list) or len(v['candidate_private'])!=len(r['stages'])):raise ValueError('unstarted/report')
    for i,(stage,private) in enumerate(zip(r['stages'],v['candidate_private'])):
        decode(FRAME+json.dumps(dict(report=stage,cookies=v['cookies'],candidate_private=private)).encode(),owner,('live','reopen')[i])
    if r['result']=='PASS':
        installed=r['installed']
        if (not r['profile_removed'] or len(r['stages'])!=2 or r['error']!='none' or any(s['result']!='PASS' for s in r['stages'])
                or not isinstance(installed,dict) or set(installed)!={'files','bytes_match'} or type(installed['files']) is not int
                or not 1<=installed['files']<=1000 or installed['bytes_match'] is not True):raise ValueError('unstarted/report')
    return v
