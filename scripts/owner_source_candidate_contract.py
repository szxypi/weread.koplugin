"""Private native captures and read-only wire plans; no write dispatcher."""
import hashlib
import json
import re

from verify_owner_reading import FRAME,RUNNER_ERRORS,decode_envelope
from source_upload_candidate import project,identifier

FLAGS={'normal_capture','page_turn_capture','retained_target','native_dom_summary',
       'legacy_units_preserved','reader_position_restored','source_gate_preserved',
       'summary_not_in_source_state','summary_not_in_settings','background_workers_observed',
       'currentness_policy_verified','currentness_receipt_invalidated'}
COUNTS=dict(candidates=3,background_workers=3,legacy_equal_source=3,failed_line=10000,preparation_failure=6,
            currentness_checks=1,
            capture_failure_state=10,capture_failure_reason=9,unexpected_retained=1,capture_origin_kind=3,next_text_visible=1)
STAGES=('page','turned','retained')
SOURCE_FIELDS={'book_id','chapter_uid','chapter_offset','file_id','book_version','raw_sha256','render_path','basis','upload_verified'}
CANDIDATE_FIELDS={'book_id','chapter_uid','chapter_idx','chapter_offset','percent','summary','basis','upload_verified'}
ERRORS={'candidate_schema','candidate_types','candidate_private','candidate_scope','candidate_frame',
        'candidate_incomplete','candidate_model','candidate_offline_changed'}


class ModelError(ValueError):
    def __init__(self,reason,index):
        super().__init__(reason)
        self.diagnostic=dict(reason=reason,checked_records=index,mode=('live','reopen')[index//3],stage=STAGES[index%3])


def integer(value,maximum):return type(value) is int and 0<=value<=maximum


def validate(value,complete):
    if not isinstance(value,dict) or set(value)!=FLAGS|set(COUNTS):raise ValueError('candidate_schema')
    if (any(type(value[k]) is not bool for k in FLAGS)
            or any(not integer(value[k],limit) for k,limit in COUNTS.items())):raise ValueError('candidate_types')
    if complete and (not all(value[k] for k in FLAGS) or value['candidates']!=3
                     or value['background_workers']!=3 or any(value[k] for k in ('failed_line','preparation_failure','capture_failure_state','capture_failure_reason','unexpected_retained','capture_origin_kind','next_text_visible'))):
        raise ValueError('candidate_incomplete')


def private(value,addon,complete):
    if (not isinstance(value,dict) or set(value)!={'records'} or not isinstance(value['records'],list)
            or len(value['records'])!=addon['candidates'] or len(value['records'])>3):raise ValueError('candidate_private')
    if complete and len(value['records'])!=3:raise ValueError('candidate_incomplete')
    for index,row in enumerate(value['records']):
        if not isinstance(row,dict) or set(row)!={'stage','source','candidate','legacy'} or row['stage']!=STAGES[index]:
            raise ValueError('candidate_private')
        source,candidate,legacy=row['source'],row['candidate'],row['legacy']
        if (not isinstance(source,dict) or set(source)!=SOURCE_FIELDS or not isinstance(candidate,dict)
                or set(candidate)!=CANDIDATE_FIELDS or not isinstance(legacy,dict)
                or set(legacy)!={'chapter_uid','chapter_idx','chapter_offset','percent'}):raise ValueError('candidate_private')
        for point in (source,candidate):
            if (identifier(point['book_id'])!=point['book_id'] or identifier(point['chapter_uid'])!=point['chapter_uid']
                    or not integer(point['chapter_offset'],2147483647) or point['basis']!='filtered_xhtml_utf16'
                    or point['upload_verified'] is not False):raise ValueError('candidate_scope')
        if (any(source[k]!=candidate[k] for k in ('book_id','chapter_uid','chapter_offset'))
                or not integer(source['book_version'],2147483647)
                or any(not isinstance(source[k],str) or not re.fullmatch('[0-9a-f]{64}',source[k]) for k in ('file_id','raw_sha256'))
                or source['render_path']!='OEBPS/text/chapter.xhtml'
                or not integer(candidate['chapter_idx'],1000000) or not integer(candidate['percent'],100)
                or identifier(legacy['chapter_uid'])!=legacy['chapter_uid'] or not integer(legacy['chapter_idx'],1000000)
                or not integer(legacy['chapter_offset'],2147483647) or legacy['percent']!=candidate['percent']
                or not integer(legacy['percent'],100)):raise ValueError('candidate_scope')
        summary=candidate['summary']
        if (not isinstance(summary,str) or not 1<=len(summary)<=20 or len(summary.encode())>80
                or any(c.isspace() or ord(c)<32 or ord(c)==127 for c in summary)):raise ValueError('candidate_private')


def decode(raw,owner,*,mode=None,full_chapters=1):
    if mode not in (None,'live','reopen') or full_chapters!=1 or not isinstance(raw,bytes) or len(raw)>2*1024*1024 or raw.count(FRAME)!=1:
        raise ValueError('candidate_frame')
    envelope=json.loads(raw.split(FRAME)[1])
    if not isinstance(envelope,dict) or set(envelope)!={'report','cookies','candidate_private'}:raise ValueError('candidate_private')
    report=envelope['report'];saved_error=None
    if mode is None:
        if not isinstance(report,dict) or not isinstance(report.get('stages'),list) or len(report['stages'])>2:
            raise ValueError('candidate_schema')
        stages=report['stages'];privates=envelope['candidate_private']
        if report.get('runner_error') in ERRORS:
            saved_error=report['runner_error'];report['runner_error']='runner_exception'
        elif report.get('runner_error') not in RUNNER_ERRORS:raise ValueError('candidate_schema')
        if not isinstance(privates,list) or len(privates)!=len(stages):raise ValueError('candidate_private')
    else:
        stages=[report];privates=[envelope['candidate_private']]
    addons=[]
    for stage,item in zip(stages,privates):
        addon=stage.pop('source_candidate')
        complete=stage.get('result')=='PASS'
        validate(addon,complete);private(item,addon,complete);addons.append(addon)
        if complete and addon['currentness_checks']!=int(stage.get('mode')=='live'):raise ValueError('candidate_incomplete')
    decoded=decode_envelope(FRAME+json.dumps(dict(report=report,cookies=envelope['cookies'])).encode(),owner,mode=mode)
    if saved_error:decoded['report']['runner_error']=saved_error
    targets=decoded['report']['stages'] if mode is None else [decoded['report']]
    for stage,addon in zip(targets,addons):stage['source_candidate']=addon
    decoded['candidate_private']=envelope['candidate_private']
    if mode is None and report.get('result')=='PASS' and privates[0]!=privates[1]:raise ValueError('candidate_offline_changed')
    return decoded


def compare(privates,raw,chapters,payload):
    digest=hashlib.sha256(raw.encode()).hexdigest()
    if digest!=payload['source_raw_sha256'] or len(privates)!=2:raise ValueError('candidate_scope')
    count=0
    for item in privates:
        for row in item['records']:
            source,candidate=row['source'],row['candidate']
            if (source['book_id']!=payload['book_id'] or source['chapter_uid']!=payload['chapter_uid']
                    or source['raw_sha256']!=digest):raise ValueError('candidate_scope')
            try:expected=project(raw,source,chapters,candidate['percent'])
            except Exception as exc:
                why={'candidate_point':'boundary','candidate_ambiguous':'ambiguous','candidate_catalog':'catalog',
                     'candidate_percent':'percent','candidate_identity':'identity'}.get(str(exc),'source')
                raise ModelError('candidate_model_'+why,count) from None
            if expected!=candidate:
                key=next((k for k in ('summary','chapter_idx','chapter_offset','percent') if expected[k]!=candidate[k]),'other')
                raise ModelError('candidate_model_'+key,count)
            count+=1
    if count!=6:raise ValueError('candidate_incomplete')
