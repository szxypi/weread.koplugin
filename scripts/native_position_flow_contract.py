"""Private native worker flow schema and fixed-label public result boundary."""
import re
from secure_native_txt_roundtrip import NATIVE_PROTOCOL,validate_plan
from verify_eink_renewal import validate_credentials
from readtime_upload_model import zone
from txt_full_summary import digest

FLAGS={'heartbeat','parent_guard_only','sqlite_before_posts','ack_journal_checked','workers_reaped','credential_audit','body_guards'}
COUNTS={'native_gets':60,'native_posts':2,'denied':32,'screenshots':0,'failed_line':10000,'completed_steps':2,'blocked_writes':1}


def validate_payload(value,armed):
    fields={'credentials','plan','native_shelf_sha256','shelf_books','guest','time_zone','permit_writes','rpc_token','mock'}
    if not isinstance(value,dict) or set(value)!=fields or value['permit_writes'] is not armed or type(value['mock']) is not bool:raise ValueError('native_position_flow/input')
    validate_credentials(value['credentials']);validate_plan(value['plan'],NATIVE_PROTOCOL)
    if (value['plan']['owner_sha256']!=digest(value['credentials']['vid']) or value['plan']['grant_sha256']!=digest(value['credentials'])
            or not isinstance(value['native_shelf_sha256'],str) or not re.fullmatch('[a-f0-9]{64}',value['native_shelf_sha256'])
            or not isinstance(value['rpc_token'],str) or not re.fullmatch('[a-f0-9]{32}',value['rpc_token'])
            or type(value['shelf_books']) is not int or not 1<=value['shelf_books']<=5000
            or not isinstance(value['guest'],str) or not 1<=len(value['guest'].encode())<=4096):raise ValueError('native_position_flow/binding')
    zone(value['time_zone'])
    if value['mock'] and value['credentials']!=dict(vid='900000',accessToken='synthetic-native-access',refreshToken='synthetic-native-refresh',deviceId='eink334691225'+'1'*19):raise ValueError('native_position_flow/mock')


def validate_stage(value,armed):
    if (not isinstance(value,dict) or set(value)!=FLAGS|set(COUNTS)|{'result','phase','permit_writes','mock'}
            or value['result'] not in ('PASS','UNVERIFIED') or value['phase'] not in ('init','start','advance','restore','audit','complete')
            or value['permit_writes'] is not armed or type(value['mock']) is not bool
            or any(type(value[k]) is not bool for k in FLAGS)
            or any(type(value[k]) is not int or not 0<=value[k]<=limit for k,limit in COUNTS.items())):raise ValueError('native_position_flow/stage')
    if value['result']=='PASS':
        if (value['phase']!='complete' or not all(value[k] for k in FLAGS) or value['denied'] or value['screenshots'] or value['failed_line']
                or value['native_posts']!=(2 if armed else 0) or value['completed_steps']!=(2 if armed else 0)
                or value['blocked_writes']!=(0 if armed else 1) or value['native_gets']<4):raise ValueError('native_position_flow/incomplete')
    return value
