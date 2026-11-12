"""Closed private ReaderUI renewal schema; never grants data write permission."""
import re
from verify_owner_reading import validate_stage as reading_stage, validate_cookies
from verify_eink_renewal import validate_credentials
from secure_native_txt_roundtrip import point
from readtime_upload_model import zone

FLAGS = {'source_reference','manual_controls','source_plan','expired_observed','renewal_saved','new_grant_snapshot',
         'dispatch_blocked','sqlite_before_block','native_file_audit','fresh_source','no_expiry'}
COUNTS = {'native_gets':80,'authentication_posts':1,'blocked_posts':1,'expired_responses':1,'native_denied':32,
          'last_native_status':599,'source_preparations':2,'failed_line':10000}


def validate_payload(value, mock_port=None):
    fields = {'book_id','chapter_uid','source_text','shelf_ids','shelf_books','source_format','source_raw_sha256',
              'source_sample_offset','vid','cookies','native_source_excerpt','native_grant','native_recovery'}
    if mock_port is not None: fields.add('reader_mock_port')
    if not isinstance(value,dict) or set(value)!=fields: raise ValueError('source_recovery/payload')
    trial=value['native_recovery']
    if (not isinstance(trial,dict) or set(trial)!={'rpc_token','baseline','target','time_zone'}
            or not isinstance(trial['rpc_token'],str) or not re.fullmatch('[a-f0-9]{32}',trial['rpc_token'])):
        raise ValueError('source_recovery/payload')
    validate_credentials(value['native_grant']);validate_cookies(value['cookies'],value['vid'])
    point(trial['baseline']);point(trial['target']);zone(trial['time_zone'])
    if (value['native_grant']['vid']!=value['vid'] or value['native_source_excerpt'] is not True or value['source_format']!='web_txt'
            or value['book_id']!=trial['baseline']['book_id'] or value['chapter_uid']!=trial['baseline']['chapter_uid']
            or any(trial['target'][k]!=trial['baseline'][k] for k in ('book_id','chapter_uid','chapter_idx'))
            or trial['target']['chapter_offset']!=trial['baseline']['chapter_offset']+1
            or not isinstance(value['source_raw_sha256'],str) or not re.fullmatch('[a-f0-9]{64}',value['source_raw_sha256'])
            or not isinstance(value['source_text'],str) or not 32<=len(value['source_text'].encode())<=128
            or type(value['source_sample_offset']) is not int or not 0<=value['source_sample_offset']<=16*1024*1024
            or type(value['shelf_books']) is not int or not 1<=value['shelf_books']<=5000
            or not isinstance(value['shelf_ids'],list) or not 1<=len(value['shelf_ids'])<=5000 or value['book_id'] not in value['shelf_ids']
            or any(not isinstance(v,str) or not re.fullmatch(r'(?:[1-9][0-9]{0,19}|CB_[A-Za-z0-9]{1,64})',v) for v in value['shelf_ids'])
            or value.get('reader_mock_port')!=mock_port): raise ValueError('source_recovery/binding')
    if mock_port is not None:
        from native_reader_fixture import GRANT,BOOK_ID
        if (type(mock_port) is not int or not 1<=mock_port<=65535 or value['native_grant']!=GRANT or value['book_id']!=BOOK_ID
                or value['cookies']!={'wr_vid':'900000','wr_skey':'mock_key'}): raise ValueError('source_recovery/mock')
    elif value['native_grant']['accessToken']=='synthetic-native-access': raise ValueError('source_recovery/mock')
    return value


def validate_stage(stage, complete=True):
    if not isinstance(stage,dict): raise ValueError('source_recovery/stage')
    a=stage.get('native_recovery')
    if (not isinstance(a,dict) or set(a)!=FLAGS|set(COUNTS)|{'phase'} or a['phase'] not in ('init','manual','complete')
            or any(type(a[k]) is not bool for k in FLAGS) or any(type(a[k]) is not int or not 0<=a[k]<=cap for k,cap in COUNTS.items())):
        raise ValueError('source_recovery/stage')
    reading_stage({k:v for k,v in stage.items() if k!='native_recovery'},'live',selection_preview=True)
    if complete:
        no_expiry=a['no_expiry']
        required={'source_reference','manual_controls','source_plan','native_file_audit'}
        recovered=FLAGS-required-{'no_expiry'}
        if (stage['result']!='PASS' or a['phase']!='complete' or a['failed_line'] or a['native_denied']
                or not all(a[k] for k in required) or any(a[k]!= (not no_expiry) for k in recovered)
                or a['authentication_posts']!=int(not no_expiry) or a['expired_responses']!=int(not no_expiry)
                or a['blocked_posts']!=int(not no_expiry) or a['source_preparations']!=(1 if no_expiry else 2)
                or a['native_gets']<(3 if no_expiry else 8)): raise ValueError('source_recovery/incomplete')
    return stage


def validate_result(value,owner):
    if (not isinstance(value,dict) or set(value)!={'result','profile_removed','installed','stage','cookies'}
            or value['result'] not in ('PASS','UNVERIFIED') or type(value['profile_removed']) is not bool):
        raise ValueError('source_recovery/result')
    validate_cookies(value['cookies'],owner)
    if value['stage'] is not None: validate_stage(value['stage'],complete=value['result']=='PASS')
    if value['result']=='PASS':
        installed=value['installed']
        if (not value['profile_removed'] or value['stage'] is None or not isinstance(installed,dict)
                or set(installed)!={'files','bytes_match'} or type(installed['files']) is not int
                or not 1<=installed['files']<=1000 or installed['bytes_match'] is not True): raise ValueError('source_recovery/incomplete')
    return value
