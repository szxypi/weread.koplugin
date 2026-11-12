"""Closed pipe/report schema for the real ReaderUI trial; no dispatch authority."""
import re
from verify_owner_reading import validate_stage as reading_stage,validate_cookies
from secure_native_close_trial import validate_plan
from verify_eink_renewal import validate_credentials
from txt_full_summary import digest
from readtime_upload_model import zone

FLAGS={'permit_writes','source_reference','baseline_readonly','document_closed','no_closed_document_calls','archive_worker','source_plan','restore_source','local_commit','sqlite_before_posts','dispatch_blocked'}
COUNTS={'native_gets':40,'native_posts':2,'blocked_posts':1,'native_denied':32,'last_native_status':599,'acknowledged':2,'steps':2,'failed_line':10000}


def validate_payload(value,armed,mock_port=None):
    fields={'book_id','chapter_uid','source_text','shelf_ids','shelf_books','source_format','source_raw_sha256','source_sample_offset',
            'vid','cookies','native_source_excerpt','native_grant','native_close_trial'}
    if mock_port is not None:fields.add('reader_mock_port')
    if not isinstance(value,dict) or set(value)!=fields:raise ValueError('close_trial/payload')
    trial=value['native_close_trial']
    if (not isinstance(trial,dict) or set(trial)!={'plan','armed','bind_percent','rpc_token','native_shelf_sha256','guest','time_zone'}
            or trial['armed'] is not armed or type(trial['bind_percent']) is not bool
            or not isinstance(trial['rpc_token'],str) or not re.fullmatch('[a-f0-9]{32}',trial['rpc_token'])
            or not isinstance(trial['native_shelf_sha256'],str) or not re.fullmatch('[a-f0-9]{64}',trial['native_shelf_sha256'])
            or not isinstance(trial['guest'],str) or not 1<=len(trial['guest'])<=4096):raise ValueError('close_trial/payload')
    validate_plan(trial['plan']);validate_credentials(value['native_grant']);validate_cookies(value['cookies'],value['vid']);zone(trial['time_zone'])
    plan=trial['plan'];grant=value['native_grant']
    if (grant['vid']!=value['vid'] or plan['owner_sha256']!=digest(value['vid']) or plan['grant_sha256']!=digest(grant)
            or value['native_source_excerpt'] is not True or value['source_format']!='web_txt'
            or value['book_id']!=plan['baseline']['book_id'] or value['chapter_uid']!=plan['baseline']['chapter_uid']
            or value['source_raw_sha256']!=plan['source_sha256'] or value.get('reader_mock_port')!=mock_port
            or not isinstance(value['source_text'],str) or not 32<=len(value['source_text'].encode())<=128
            or type(value['source_sample_offset']) is not int or not 0<=value['source_sample_offset']<=16*1024*1024
            or type(value['shelf_books']) is not int or not 1<=value['shelf_books']<=5000
            or not isinstance(value['shelf_ids'],list) or not 1<=len(value['shelf_ids'])<=5000
            or value['book_id'] not in value['shelf_ids']
            or any(not isinstance(key,str) or not re.fullmatch(r'(?:[1-9][0-9]{0,19}|CB_[A-Za-z0-9]{1,64})',key) for key in value['shelf_ids'])):
        raise ValueError('close_trial/binding')
    if mock_port is not None:
        from native_reader_fixture import GRANT,BOOK_ID
        if (type(mock_port) is not int or not 1<=mock_port<=65535 or grant!=GRANT or value['book_id']!=BOOK_ID
                or value['cookies']!={'wr_vid':'900000','wr_skey':'mock_key'}):raise ValueError('close_trial/mock')
    elif grant['accessToken']=='synthetic-native-access':raise ValueError('close_trial/mock')
    return value


def validate_stage(stage,armed,complete=True):
    if not isinstance(stage,dict):raise ValueError('close_trial/stage')
    a=stage.get('native_close_trial')
    if (not isinstance(a,dict) or set(a)!=FLAGS|set(COUNTS)|{'phase'} or a['permit_writes'] is not armed
            or a['phase'] not in ('init','close','restore','complete') or any(type(a[k]) is not bool for k in FLAGS)
            or any(type(a[k]) is not int or not 0<=a[k]<=cap for k,cap in COUNTS.items())):raise ValueError('close_trial/stage')
    reading_stage({k:v for k,v in stage.items() if k!='native_close_trial'},'live',selection_preview=True)
    if complete and (stage['result']!='PASS' or a['phase']!='complete' or a['failed_line'] or a['native_denied']
            or not all(a[k] for k in ('source_reference','baseline_readonly','document_closed','no_closed_document_calls','archive_worker','source_plan','sqlite_before_posts'))
            or a['steps']!=(2 if armed else 0) or a['native_posts']!=(2 if armed else 0) or a['acknowledged']!=(2 if armed else 0)
            or a['blocked_posts']!=(0 if armed else 1) or a['dispatch_blocked'] is armed
            or a['restore_source'] is not armed or a['local_commit'] is not armed or a['native_gets']<7):raise ValueError('close_trial/incomplete')
    return stage


def validate_result(value,armed,owner):
    if (not isinstance(value,dict) or set(value)!={'result','profile_removed','installed','stage','cookies'}
            or value['result'] not in ('PASS','UNVERIFIED') or type(value['profile_removed']) is not bool):raise ValueError('close_trial/result')
    validate_cookies(value['cookies'],owner)
    if value['stage'] is not None:validate_stage(value['stage'],armed,complete=value['result']=='PASS')
    if value['result']=='PASS':
        installed=value['installed']
        if (not value['profile_removed'] or value['stage'] is None or not isinstance(installed,dict)
                or set(installed)!={'files','bytes_match'} or type(installed['files']) is not int
                or not 1<=installed['files']<=1000 or installed['bytes_match'] is not True):raise ValueError('close_trial/incomplete')
    return value
