"""Explicit no-chapter observations, distinct from positive native positions."""
from copy import deepcopy
import re
from verify_reader_progress import project,find_node
from source_remote_position import outcome
from secure_native_txt_roundtrip import point,HASH_FIELDS
from secure_weread_session import StoreError
from readtime_upload_model import integer

PROTOCOL='native-first-chapter-raw-30-zero-time-v1'
COUNTERS={'readingTime','recordReadingTime','ttsTime'}
FIELDS={'kind','book_id','chapter_uid','chapter_offset','raw_percent','index_present','summary_present'}


def no_chapter(raw,book):
    if outcome(raw,book,[]).get('reason')!='progress_no_chapter':raise ValueError('initial_position/not_no_chapter')
    p=project(raw,book);node=find_node(raw,book)
    out=dict(kind='no_chapter',book_id=book,chapter_uid='0',chapter_offset=0,raw_percent=0,
             index_present=any(k in node for k in ('chapterIdx','chapterIndex','chapter_idx')),
             summary_present=any(k in node for k in ('summary','chapterTitle')))
    if out['index_present']:out['chapter_idx']=p['chapter_idx']
    if out['summary_present']:out['summary']=p['summary']
    valid_no_chapter(out);return out


def valid_no_chapter(value):
    if not isinstance(value,dict):raise StoreError('initial_position/no_chapter')
    expected=FIELDS|({'chapter_idx'} if value.get('index_present') is True else set())|({'summary'} if value.get('summary_present') is True else set())
    if (set(value)!=expected or value.get('kind')!='no_chapter' or type(value.get('index_present')) is not bool or type(value.get('summary_present')) is not bool
            or not isinstance(value.get('book_id'),str) or not re.fullmatch('[1-9][0-9]{0,19}',value['book_id'])
            or value.get('chapter_uid')!='0' or type(value.get('chapter_offset')) is not int or value['chapter_offset']!=0
            or type(value.get('raw_percent')) is not int or value['raw_percent']!=0
            or value['index_present'] and (type(value['chapter_idx']) is not int or value['chapter_idx']!=0)
            or value['summary_present'] and value['summary']!=''):raise StoreError('initial_position/no_chapter')


def counts(raw,book):
    node=find_node(raw,book);out={k:node.get(k) for k in COUNTERS}
    if any(not integer(v,0,2**53-1) for v in out.values()):raise ValueError('initial_position/counts')
    return out


def validate_plan(value):
    fields=HASH_FIELDS|{'protocol','native_shelf_sha256','baseline','target','counts','version','source_file_id'}
    if (not isinstance(value,dict) or set(value)!=fields or value['protocol']!=PROTOCOL
            or any(not isinstance(value[k],str) or not re.fullmatch('[a-f0-9]{64}',value[k]) for k in HASH_FIELDS|{'native_shelf_sha256','source_file_id'})
            or not isinstance(value['baseline'],dict) or set(value['baseline'])!={'web','native'}):raise StoreError('initial_position/plan')
    for state in value['baseline'].values():valid_no_chapter(state)
    try:point(value['target'])
    except (ValueError,StoreError):raise StoreError('initial_position/target') from None
    if (any(s['book_id']!=value['target']['book_id'] for s in value['baseline'].values())
            or type(value['target']['raw_percent']) is not int or len(value['target']['summary'])!=30
            or not integer(value['version'],0,2147483647) or not isinstance(value['counts'],dict) or set(value['counts'])!=COUNTERS
            or any(type(v) is not int or v!=0 for v in value['counts'].values())):raise StoreError('initial_position/plan')
    return deepcopy(value)
