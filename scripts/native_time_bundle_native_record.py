"""Compare a native worker's private journal record with a preflight baseline.

This is an offline contract. A caller must authenticate the worker and provide
the bound archive path; it does not establish network provenance or send data.
"""
import base64
import hashlib
import io
import os
from pathlib import Path
import re
import stat
import zipfile

from native_time_bundle_gate import day
from native_time_bundle_selection import native_digest,validate_selection
from native_time_capture_evidence import account_key
from readtime_upload_model import integer
from verify_native_position_lua import equivalent
from web_shelf_contract import identity


def point_hash(point,book):
    keys={'chapter_uid','chapter_idx','chapter_offset','raw_percent','summary','chapterTitle'}
    if not isinstance(point,dict) or set(point)!=keys:raise ValueError('native_record/point')
    value={'contract':'historical-time-point-presence-v1','book_id':book,'chapter_uid':identity(point['chapter_uid']),
           'chapter_idx':point['chapter_idx'],'chapter_offset':point['chapter_offset'],'raw_percent':point['raw_percent'],
           'summary':point['summary'],'chapter_title':point['chapterTitle']}
    return native_digest(value)


def archive_details(plan,source_path):
    if not isinstance(source_path,(str,Path)) or not Path(source_path).is_absolute() or '\0' in str(source_path):
        raise ValueError('native_record/archive')
    expected=base64.b64decode(plan['archive_base64'],validate=True)
    fd=None
    try:
        fd=os.open(source_path,os.O_RDONLY|getattr(os,'O_NOFOLLOW',0)|getattr(os,'O_NONBLOCK',0)|getattr(os,'O_CLOEXEC',0))
        info=os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size!=len(expected) or info.st_size>2*1024*1024:
            raise ValueError()
        with os.fdopen(fd,'rb') as stream:
            fd=None;actual=stream.read(len(expected)+1)
        if actual!=expected or hashlib.sha256(actual).hexdigest()!=plan['archive_sha256']:raise ValueError()
        with zipfile.ZipFile(io.BytesIO(actual)) as archive:
            path='OEBPS/weread-position/uid-'+hashlib.sha256(plan['chapter_uid'].encode()).hexdigest()+'.meta'
            metadata=archive.read(path);raw=archive.read('OEBPS/weread-position/raw-'+plan['raw_sha256']+'.txt')
        return hashlib.sha256(metadata).hexdigest(),len(raw)
    except Exception:raise ValueError('native_record/archive') from None
    finally:
        if fd is not None:os.close(fd)


def validate_record(bundle,grant,evidence,selection,body,record,source_path,now):
    _report,snapshot,months=evidence.for_bundle(bundle,grant);p=bundle['plan']
    validate_selection(bundle,selection)
    if (not isinstance(record,dict) or set(record)!={'attempt','account','phase','metadata','rows','request_hash','created'}
            or not isinstance(record['attempt'],str) or not re.fullmatch(r'offtime-v1:[a-f0-9]{32}',record['attempt'])
            or record['account']!=account_key(p['owner']) or record['phase']!='claimed'
            or not integer(record['created'],p['not_before'],4102444800)
            or not integer(now,p['not_before'],4102444800) or not 0<=now-record['created']<30
            or not isinstance(body,dict) or not isinstance(body.get('books'),list) or len(body['books'])!=1
            or not isinstance(body['books'][0],dict)):
        raise ValueError('native_record/record')
    rows=record['rows'];wanted=selection['rows']
    if (not isinstance(rows,list) or len(rows)!=len(wanted) or any(not isinstance(r,dict) or set(r)!=set(wanted[0])
            or not integer(r['id'],1,2**53-1) for r in rows) or len({r['id'] for r in rows})!=len(rows)
            or any(not equivalent({k:v for k,v in actual.items() if k!='id'},
                                  {k:v for k,v in original.items() if k!='id'}) for actual,original in zip(rows,wanted))):
        raise ValueError('native_record/rows')
    metadata=record['metadata'];source=metadata.get('source') if isinstance(metadata,dict) else None
    meta_hash,raw_bytes=archive_details(p,source_path)
    expected_source={'expected':{'book_id':p['book_id'],'chapter_uid':p['chapter_uid'],'chapter_idx':p['chapter_idx'],
                                 'raw_sha256':p['raw_sha256'],'raw_bytes':raw_bytes},
                     'format':p['format'],'metadata_hash':meta_hash,
                     'ref':{'file':str(source_path),'chapter_uid':p['chapter_uid'],'chapter_idx':p['chapter_idx']}}
    if not isinstance(source,dict) or set(source)!=set(expected_source)|{'catalog_stamp'}:
        raise ValueError('native_record/source')
    if (not isinstance(source['catalog_stamp'],str) or not re.fullmatch('[a-f0-9]{64}',source['catalog_stamp'])
            or not equivalent({k:source[k] for k in expected_source},expected_source)):
        raise ValueError('native_record/source')
    stamp=body['books'][0].get('timestamp');request_hash=native_digest(body)
    expected={'protocol':'native-historical-time-cst-v1','position_contract':'historical-time-point-presence-v1',
              'book_id':p['book_id'],'file_id':p['file_id'],'book_version':p['book_version'],'seconds':p['seconds'],
              'day':day(p['start_time']),'created_at':stamp,'device_hash':native_digest(grant['deviceId']),
              'source':source,'native_hash':point_hash(snapshot['point'],p['book_id']),
              'web_hash':point_hash(snapshot['web_point'],p['book_id']),'counts':snapshot['counts'],
              'shelf_hash':snapshot['shelf'],'months':months,'request_hash':request_hash}
    if (not integer(stamp,p['not_before'],4102444800) or record['created']<stamp or day(now)!=day(stamp)
            or record['request_hash']!=request_hash or not equivalent(metadata,expected)):
        raise ValueError('native_record/baseline')
    return True
