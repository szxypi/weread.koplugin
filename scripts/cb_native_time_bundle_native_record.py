"""Validate a CB worker's claimed journal against sealed preflight evidence."""
import re
from pathlib import Path

from cb_native_time_bundle_evidence import PreflightEvidence
from cb_native_time_bundle_gate import day
from native_time_bundle_native_record import archive_details,archive_details_bytes,point_hash
from native_time_bundle_selection import native_digest,validate_selection
from native_time_capture_evidence import account_key
from readtime_upload_model import integer
from verify_native_position_lua import equivalent


def validate_record(bundle,grant,evidence,selection,body,record,source_path,now,*,archive=None):
    if not isinstance(evidence,PreflightEvidence):raise ValueError('cb_native_record/evidence')
    _report,snapshot,months=evidence.for_bundle(bundle,grant);plan=bundle['plan']
    validate_selection(bundle,selection,imported=True)
    if (not isinstance(record,dict) or set(record)!={'attempt','account','phase','metadata','rows','request_hash','created'}
            or not isinstance(record['attempt'],str) or not re.fullmatch(r'offtime-v1:[a-f0-9]{32}',record['attempt'])
            or record['account']!=account_key(plan['owner']) or record['phase']!='claimed'
            or not integer(record['created'],plan['not_before'],4102444800)
            or not integer(now,plan['not_before'],4102444800) or not 0<=now-record['created']<30
            or not isinstance(body,dict) or not isinstance(body.get('books'),list) or len(body['books'])!=1
            or not isinstance(body['books'][0],dict)):raise ValueError('cb_native_record/record')
    rows=record['rows'];wanted=selection['rows']
    if (not isinstance(rows,list) or len(rows)!=len(wanted) or any(not isinstance(row,dict) or set(row)!=set(wanted[0])
            or not integer(row['id'],1,2**53-1) for row in rows) or len({row['id'] for row in rows})!=len(rows)
            or any(not equivalent({key:value for key,value in actual.items() if key!='id'},
                                  {key:value for key,value in original.items() if key!='id'})
                   for actual,original in zip(rows,wanted))):raise ValueError('cb_native_record/rows')
    metadata=record['metadata'];source=metadata.get('source') if isinstance(metadata,dict) else None
    if not isinstance(source_path,(str,Path)) or not Path(source_path).is_absolute() or '\0' in str(source_path):
        raise ValueError('cb_native_record/source')
    meta_hash,raw_bytes=archive_details(plan,source_path) if archive is None else archive_details_bytes(plan,archive)
    expected_source={'expected':{'book_id':plan['book_id'],'chapter_uid':plan['chapter_uid'],'chapter_idx':plan['chapter_idx'],
                                 'raw_sha256':plan['raw_sha256'],'raw_bytes':raw_bytes},
                     'format':plan['format'],'metadata_hash':meta_hash,
                     'ref':{'file':str(source_path),'chapter_uid':plan['chapter_uid'],'chapter_idx':plan['chapter_idx']}}
    if (not isinstance(source,dict) or set(source)!=set(expected_source)|{'catalog_stamp'}
            or source['catalog_stamp']!=evidence.catalog_stamp(bundle,grant)
            or not equivalent({key:source[key] for key in expected_source},expected_source)):
        raise ValueError('cb_native_record/source')
    stamp=body['books'][0].get('timestamp');request_hash=native_digest(body)
    expected={'protocol':'native-historical-time-cst-cb-v1','position_contract':'historical-time-point-presence-v1',
              'book_id':plan['book_id'],'file_id':plan['file_id'],'book_version':plan['book_version'],'seconds':plan['seconds'],
              'day':day(plan['start_time']),'created_at':stamp,'device_hash':native_digest(grant['deviceId']),
              'source':source,'native_hash':point_hash(snapshot['native'],plan['book_id']),
              'web_hash':point_hash(snapshot['web'],plan['book_id']),'counts':snapshot['counts'],
              'shelf_hash':snapshot['native_shelf'],'months':months,'request_hash':request_hash}
    if (not integer(stamp,plan['not_before'],4102444800) or record['created']<stamp or day(now)!=day(stamp)
            or record['request_hash']!=request_hash or not equivalent(metadata,expected)):
        raise ValueError('cb_native_record/baseline')
    return True
