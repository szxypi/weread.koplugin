"""Independent constraints for one native-chapter current-day test send."""
import re
import time
from pathlib import PurePosixPath

from native_time_bundle_native_record import point_hash
from native_time_bundle_selection import native_digest
from native_time_capture_evidence import account_key
from readtime_upload_model import batch,integer,validate_rows
from verify_native_position_lua import equivalent


def valid_hash(value):return isinstance(value,str) and re.fullmatch('[a-f0-9]{64}',value) is not None


def day(stamp):return (stamp+28800)//86400*86400-28800


def validate_selection(selection,reference,expected,seconds,now=None):
    now=int(time.time()) if now is None else now
    fields={'book_id','file_id','book_version','time_zone','seconds','rows','parts','protocol_rows','rows_hash','parts_hash',
            'native_direct','current_day'}
    if (not isinstance(selection,dict) or set(selection)!=fields or selection['book_id']!=expected['book_id']
            or selection['book_version']!=expected['version'] or selection['time_zone']!='+08:00'
            or selection['native_direct'] is not True or selection['current_day'] is not True
            or not valid_hash(selection['file_id']) or not integer(seconds,5,20) or selection['seconds']!=seconds):
        raise ValueError('direct_time/selection')
    rows=selection['rows'];parts=selection['parts'];protocol=selection['protocol_rows']
    if (not isinstance(rows,list) or not 1<=len(rows)<=20 or not isinstance(parts,list) or len(parts)!=len(rows)
            or not isinstance(protocol,list) or len(protocol)!=len(parts)
            or selection['rows_hash']!=native_digest(rows) or selection['parts_hash']!=native_digest(parts)):
        raise ValueError('direct_time/selection')
    row_fields={'id','book_id','start_time','duration','time_zone','book_version','file_id','version_source'}
    by_id={}
    for row in rows:
        if (not isinstance(row,dict) or set(row)!=row_fields or not integer(row['id'],1,2**53-1)
                or row['id'] in by_id or row['book_id']!=expected['book_id'] or row['file_id']!=selection['file_id']
                or row['book_version']!=expected['version'] or row['time_zone']!='+08:00'
                or row['version_source']!='native_direct' or not integer(row['start_time'],1,now)
                or not integer(row['duration'],1,60) or not 0<=now-row['start_time']<=180
                or row['start_time']+row['duration']>now or day(row['start_time'])!=day(now)
                or day(row['start_time']+row['duration']-1)!=day(now)):
            raise ValueError('direct_time/rows')
        by_id[row['id']]=row
    seen=set();expected_protocol=[]
    for part in parts:
        if not isinstance(part,dict) or set(part)!={'row_id','start_time','duration'} or part['row_id'] not in by_id or part['row_id'] in seen:
            raise ValueError('direct_time/parts')
        row=by_id[part['row_id']];seen.add(part['row_id'])
        if part['start_time']!=row['start_time'] or part['duration']!=row['duration']:raise ValueError('direct_time/parts')
        expected_protocol.append({key:row[key] for key in ('start_time','duration','time_zone','book_version')})
    if protocol!=expected_protocol or sum(row['duration'] for row in rows)!=seconds or validate_rows(protocol,expected['book_id'],now)!=seconds:
        raise ValueError('direct_time/interval')
    if (not isinstance(reference,dict) or set(reference)!={'kind','file','chapter_uid','source_sha256'}
            or reference['kind']!='native_direct' or reference['chapter_uid']!=expected['uid']
            or reference['source_sha256']!=expected['source_sha256'] or not isinstance(reference['file'],str)):
        raise ValueError('direct_time/source')
    path=PurePosixPath(reference['file'])
    if (not path.is_absolute() or '..' in path.parts or len(path.parts)<7 or path.parts[1]!='dev' or path.parts[2]!='shm'
            or not path.parts[3].startswith('weread-direct-time-trial-') or path.parts[4:7]!=('profile','weread','native-reader-v1')):
        raise ValueError('direct_time/source')
    return selection


def validate_claim(event,selection,reference,expected,baseline,grant,now=None):
    now=int(time.time()) if now is None else now
    if not isinstance(event,dict) or set(event)!={'kind','body','selection','record'} or event['kind']!='claim' \
            or not equivalent(event['selection'],selection):raise ValueError('direct_time/claim')
    record=event['record'];body=event['body']
    if (not isinstance(record,dict) or set(record)!={'attempt','account','phase','metadata','rows','request_hash','created'}
            or not isinstance(record['attempt'],str) or not re.fullmatch('offtime-v1:[a-f0-9]{32}',record['attempt'])
            or record['account']!=account_key(grant['vid']) or record['phase']!='claimed'
            or not integer(record['created'],now-30,now+2) or not isinstance(record['metadata'],dict)
            or not isinstance(record['rows'],list) or len(record['rows'])!=len(selection['parts'])
            or not isinstance(body,dict) or not isinstance(body.get('books'),list) or len(body['books'])!=1):
        raise ValueError('direct_time/record')
    metadata=record['metadata'];source=metadata.get('source');inner=body['books'][0]
    if not isinstance(inner,dict) or not isinstance(source,dict):raise ValueError('direct_time/record')
    for actual,part in zip(record['rows'],selection['parts']):
        if (actual.get('book_id')!=expected['book_id'] or actual.get('file_id')!=selection['file_id']
                or actual.get('book_version')!=expected['version'] or actual.get('version_source')!='native_direct'
                or actual.get('time_zone')!='+08:00' or actual.get('start_time')!=part['start_time']
                or actual.get('duration')!=part['duration']):raise ValueError('direct_time/record_rows')
    if (source.get('kind')!='native_direct' or source.get('ref')!=reference or source.get('account')!=record['account']
            or source.get('book_id')!=expected['book_id'] or source.get('chapter_uid')!=expected['uid']
            or source.get('file_id')!=selection['file_id'] or source.get('book_version')!=expected['version']
            or source.get('source_sha256')!=expected['source_sha256'] or not valid_hash(source.get('catalog_stamp'))
            or not integer(source.get('chapter_idx'),0,1000000)):
        raise ValueError('direct_time/source')
    stamp=inner.get('timestamp')
    if not integer(stamp,now-30,now+2) or day(stamp)!=day(now):raise ValueError('direct_time/clock')
    calculated=batch(grant,expected['book_id'],selection['protocol_rows'],baseline['guest'],baseline['config_token'],stamp,
        inner.get('random'),body.get('timestamp'),body.get('random'),current_zone='+08:00')
    if not equivalent(calculated,body):raise ValueError('direct_time/signature')
    request_hash=native_digest(body)
    values={'protocol':'native-current-time-cst-v1','position_contract':'historical-time-point-presence-v1',
        'book_id':expected['book_id'],'file_id':selection['file_id'],'book_version':expected['version'],
        'seconds':selection['seconds'],'day':day(stamp),'created_at':stamp,'device_hash':native_digest(grant['deviceId']),
        'native_hash':point_hash(baseline['native_point'],expected['book_id']),
        'web_hash':point_hash(baseline['web_point'],expected['book_id']),'counts':baseline['counts'],
        'shelf_hash':baseline['shelf_hash'],'months':baseline['months'],'request_hash':request_hash}
    if (record['request_hash']!=request_hash or any(not equivalent(metadata.get(key),value) for key,value in values.items())
            or set(metadata)!=set(values)|{'source'}):raise ValueError('direct_time/baseline')
    return True
