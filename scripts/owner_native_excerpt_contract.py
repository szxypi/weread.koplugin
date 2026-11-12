"""Strict private reader/source excerpts, not a cloud upload contract."""
import hashlib
import json
import re
from txt_coordinates import PlainSource
from verify_owner_reading import FRAME,decode_envelope
from owner_source_candidate_contract import SOURCE_FIELDS,STAGES,integer
from source_upload_candidate import identifier

FLAGS={'normal_capture','page_turn_capture','retained_target','parent_native_guard','opaque_receipts',
       'movement_invalidates_receipt','source_gate_preserved','legacy_units_preserved','position_restored',
       'text_not_in_source_state','text_not_in_settings','page_child_cancelled','close_child_cancelled','fresh_policy_verified'}
COUNTS={'background_workers':3,'excerpts':3,'failed_line':10000,'denied_shape':4,'denied_checks':255,'denied_api':4,'currentness_checks':1}
EXCERPT_FIELDS={'text','co','end_co','scalars','basis','upload_verified'}


def validate(addon,records,complete):
    if (not isinstance(addon,dict) or set(addon)!=FLAGS|set(COUNTS)
            or any(type(addon[k]) is not bool for k in FLAGS)
            or any(not integer(addon[k],limit) for k,limit in COUNTS.items())
            or not isinstance(records,dict) or set(records)!={'records'} or not isinstance(records['records'],list)
            or len(records['records'])!=addon['excerpts']):raise ValueError('native_excerpt/schema')
    if complete and (not all(addon[k] for k in FLAGS) or addon['background_workers']!=3 or addon['excerpts']!=3
                     or any(addon[k] for k in ('failed_line','denied_shape','denied_checks','denied_api'))):
        raise ValueError('native_excerpt/incomplete')
    for index,row in enumerate(records['records']):
        if not isinstance(row,dict) or set(row)!={'stage','packet','legacy'} or row['stage']!=STAGES[index]:raise ValueError('native_excerpt/order')
        packet,legacy=row['packet'],row['legacy']
        if not isinstance(packet,dict) or set(packet)!={'position','excerpt'}:raise ValueError('native_excerpt/packet')
        p,e=packet['position'],packet['excerpt']
        if not isinstance(p,dict) or set(p)!=SOURCE_FIELDS or not isinstance(e,dict) or set(e)!=EXCERPT_FIELDS:raise ValueError('native_excerpt/packet')
        if (any(not isinstance(p[k],str) or identifier(p[k])!=p[k] for k in ('book_id','chapter_uid'))
                or p['basis']!='raw_txt_utf16' or p['upload_verified'] is not False
                or not integer(p['chapter_offset'],2147483647) or not integer(p['book_version'],2147483647)
                or any(not isinstance(p[k],str) or not re.fullmatch('[0-9a-f]{64}',p[k]) for k in ('raw_sha256','file_id'))
                or p['render_path']!='OEBPS/text/chapter.xhtml'):raise ValueError('native_excerpt/source')
        if (not isinstance(e['text'],str) or not 1<=len(e['text'])<=30 or e['basis']!='raw_txt_utf16'
                or e['upload_verified'] is not False or not integer(e['co'],2147483647) or e['co']!=p['chapter_offset']
                or not integer(e['end_co'],2147483647) or not integer(e['scalars'],30)
                or PlainSource(e['text']).excerpt(0)['end_co']+e['co']!=e['end_co'] or len(e['text'])!=e['scalars']):
            raise ValueError('native_excerpt/boundary')
        if (not isinstance(legacy,dict) or set(legacy)!={'chapter_uid','chapter_idx','chapter_offset','percent'}
                or identifier(legacy['chapter_uid'])!=p['chapter_uid']
                or not integer(legacy['chapter_idx'],1000000) or not integer(legacy['chapter_offset'],2147483647)
                or not integer(legacy['percent'],100)):raise ValueError('native_excerpt/legacy')


def decode(raw,owner,*,mode=None,full_chapters=1):
    if mode not in (None,'live','reopen') or full_chapters!=1 or not isinstance(raw,bytes) or len(raw)>2*1024*1024 or raw.count(FRAME)!=1:
        raise ValueError('native_excerpt/frame')
    value=json.loads(raw.split(FRAME)[1])
    if not isinstance(value,dict) or set(value)!={'report','cookies','candidate_private'}:raise ValueError('native_excerpt/envelope')
    report=value['report'];installed=None
    if not isinstance(report,dict):raise ValueError('native_excerpt/report')
    stages=report.get('stages') if mode is None else [report]
    privates=value['candidate_private'] if mode is None else [value['candidate_private']]
    if not isinstance(stages,list) or len(stages)>2 or not isinstance(privates,list) or len(stages)!=len(privates):raise ValueError('native_excerpt/stages')
    if mode is None:
        installed=report.pop('installed_package',None)
        if installed is not None and (not isinstance(installed,dict) or set(installed)!={'files','bytes_match'}
                or not integer(installed['files'],1000) or installed['files']<1 or installed['bytes_match'] is not True):raise ValueError('native_excerpt/package')
        if report.get('result')=='PASS' and not installed:raise ValueError('native_excerpt/package')
    addons=[]
    for stage,private in zip(stages,privates):
        addon=stage.pop('native_source_excerpt',None);validate(addon,private,stage.get('result')=='PASS');addons.append(addon)
        if stage.get('result')=='PASS' and addon['currentness_checks']!=int(stage.get('mode')=='live'):raise ValueError('native_excerpt/freshness')
    decoded=decode_envelope(FRAME+json.dumps(dict(report=report,cookies=value['cookies'])).encode(),owner,mode=mode)
    targets=decoded['report']['stages'] if mode is None else [decoded['report']]
    for stage,addon in zip(targets,addons):stage['native_source_excerpt']=addon
    if installed is not None:decoded['report']['installed_package']=installed
    if mode is None and report.get('result')=='PASS' and privates[0]!=privates[1]:raise ValueError('native_excerpt/offline_changed')
    decoded['candidate_private']=value['candidate_private'];return decoded


def compare(privates,raw,payload):
    digest=hashlib.sha256(raw.encode()).hexdigest();model=PlainSource(raw)
    if digest!=payload['source_raw_sha256'] or len(privates)!=2:raise ValueError('native_excerpt/scope')
    count=0
    for item in privates:
        for row in item['records']:
            p,e=row['packet']['position'],row['packet']['excerpt']
            if p['book_id']!=payload['book_id'] or p['chapter_uid']!=payload['chapter_uid'] or p['raw_sha256']!=digest:
                raise ValueError('native_excerpt/scope')
            if e!=model.excerpt(p['chapter_offset']):raise ValueError('native_excerpt/model')
            count+=1
    if count!=6:raise ValueError('native_excerpt/incomplete')
