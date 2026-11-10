"""Strict receipts for an explicitly armed real native experiment."""
import json
import re

from verify_owner_reading import FRAME, RUNNER_ERRORS, decode_envelope, validate_cookies
from owner_progress_preview_contract import private as validate_records, compare as compare_records

FLAGS={'source_points_verified','actual_upload_service','same_position_confirmed','probe_confirmed','probe_seen',
       'restore_acknowledged','restoration_verified','reader_position_restored','source_upload_gate_preserved',
       'safe_resolution','unrelated_position_seen','disarmed','permission_blocked'}
COUNTS=dict(guard_denied=1024,posts_attempted=4,guard_reads=24,synthetic_acknowledgements=0,failed_line=10000)
FAILURES={'none','position_changed','same_unconfirmed','probe_unconfirmed','preparation_failed','restore_unconfirmed'}
ERRORS={'experiment_schema','experiment_types','experiment_status','experiment_receipt','experiment_scope',
        'experiment_private','experiment_runner','experiment_frame','experiment_unverified'}


def validate(value):
    if not isinstance(value,dict) or set(value)!=FLAGS|set(COUNTS)|{'result','failure','post_statuses'}:raise ValueError('experiment_schema')
    if (value['result'] not in ('PASS','UNVERIFIED') or value['failure'] not in FAILURES
            or any(type(value[k]) is not bool for k in FLAGS)
            or any(type(value[k]) is not int or not 0<=value[k]<=n for k,n in COUNTS.items())):raise ValueError('experiment_types')
    statuses=value['post_statuses']
    if not isinstance(statuses,list) or len(statuses)!=value['posts_attempted'] or any(type(n) is not int or not 0<=n<=599 for n in statuses):
        raise ValueError('experiment_status')
    if value['safe_resolution'] and (not value['restoration_verified'] or any(n!=200 for n in statuses)
            or value['posts_attempted']>=3 and (value['posts_attempted']!=4 or not value['probe_seen'])):
        raise ValueError('experiment_status')
    if value['disarmed'] and value['posts_attempted']:raise ValueError('experiment_status')
    if value['result']=='PASS' and (not all(value[k] for k in FLAGS-{'unrelated_position_seen','disarmed','permission_blocked'})
            or value['unrelated_position_seen'] or value['disarmed'] or value['permission_blocked']
            or value['posts_attempted']!=4 or value['guard_denied'] or value['failed_line']
            or value['failure']!='none' or statuses!=[200]*4):raise ValueError('experiment_status')


def private(value,addon):
    if (not isinstance(value,dict) or set(value)!={'records','guard_installed','intent_digest'}
            or value['guard_installed'] is not True or not isinstance(value['intent_digest'],str)
            or not (value['intent_digest']=='' if addon['disarmed'] else re.fullmatch('[0-9a-f]{64}',value['intent_digest']))):
        raise ValueError('experiment_receipt')
    validate_records(dict(records=value['records']),addon['result']=='PASS')
    if len(value['records'])!=addon['posts_attempted']:raise ValueError('experiment_receipt')


def decode(raw,owner,*,mode=None,full_chapters=1):
    if mode not in (None,'live') or full_chapters!=1 or not isinstance(raw,bytes) or len(raw)>2*1024*1024 or raw.count(FRAME)!=1:
        raise ValueError('experiment_frame')
    envelope=json.loads(raw.split(FRAME)[1])
    if not isinstance(envelope,dict) or set(envelope)!={'report','cookies','progress_private'}:raise ValueError('experiment_private')
    report=envelope['report']
    if mode is None:
        if (not isinstance(report,dict) or set(report)!={'result','tmpfs_profile','profile_removed','stages','runner_error'}
                or report['result'] not in ('PASS','UNVERIFIED') or type(report['tmpfs_profile']) is not bool
                or type(report['profile_removed']) is not bool or report['runner_error'] not in RUNNER_ERRORS|ERRORS
                or not isinstance(report['stages'],list) or len(report['stages'])>1):raise ValueError('experiment_runner')
        if not report['stages']:
            if report['result']!='UNVERIFIED' or envelope['progress_private'] is not None:raise ValueError('experiment_runner')
            validate_cookies(envelope['cookies'],owner);return envelope
        if report['result']=='PASS' and (not report['tmpfs_profile'] or not report['profile_removed'] or report['runner_error']!='none'):
            raise ValueError('experiment_runner')
        stage=report['stages'][0]
    else:stage=report
    addon=stage.pop('progress_roundtrip');validate(addon);private(envelope['progress_private'],addon)
    decode_envelope(FRAME+json.dumps(dict(report=stage,cookies=envelope['cookies'])).encode(),owner,mode='live')
    stage['progress_roundtrip']=addon
    if mode is None and report['result']=='PASS' and (stage['result']!='PASS' or addon['result']!='PASS'):
        raise ValueError('experiment_unverified')
    return envelope


def compare(records,plan,started,finished):
    compare_records(records,plan,started,finished,allow_partial=True)
