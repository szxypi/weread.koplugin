"""Strict metadata-only framing for the native membership acceptance probe."""
import json
import re

FRAME=b'\nWEREAD_OWNER_MEMBERSHIP_RESULT='
FLAGS={'anonymous_credentials','guard_selftest','native_detail','preview_matches','native_confirmation','worker_heartbeat',
       'cancel_no_post','status_close_cancelled','workers_reaped','credential_audit','local_state_preserved',
       'roundtrip_restored','no_authentication_posts','journal_before_posts','native_cache_readback'}
COUNTS={'shelf_books':5000,'profile_files_audited':1024,'screenshots':0,'failed_line':10000,'denied_route':8}
PHASES={'init','detail','preview','cancel','close','recreate','add','remove','audit','complete'}
ERRORS={'none','candidate_layout','input_limit','child_timeout','runner_exception','stage_unverified'}
ERRORS|={'membership_frame','membership_envelope','membership_stage_schema','membership_stage_types',
         'membership_stage_requests','membership_stage_incomplete','membership_receipt'}


def validate_stage(value,apply):
    if not isinstance(value,dict) or set(value)!=FLAGS|set(COUNTS)|{'result','phase','request_counts','post_statuses','permit_writes'}:
        raise ValueError('membership_stage_schema')
    if (not isinstance(value['result'],str) or value['result'] not in ('PASS','UNVERIFIED')
            or not isinstance(value['phase'],str) or value['phase'] not in PHASES
            or value['permit_writes'] is not apply or any(type(value[key]) is not bool for key in FLAGS)
            or any(type(value[key]) is not int or not 0<=value[key]<=limit for key,limit in COUNTS.items())):
        raise ValueError('membership_stage_types')
    counts=value['request_counts'];statuses=value['post_statuses']
    if (not isinstance(counts,list) or len(counts)!=5 or any(type(n) is not int or not 0<=n<=limit for n,limit in zip(counts,(13,1,1,1,1024)))
            or not isinstance(statuses,list) or len(statuses)!=counts[2]+counts[3]
            or any(type(n) is not int or not 0<=n<=599 for n in statuses)
            or not apply and (counts[2] or counts[3] or value['roundtrip_restored'])):raise ValueError('membership_stage_requests')
    needed=FLAGS-({'roundtrip_restored','journal_before_posts','native_cache_readback'} if not apply else set())
    if value['result']=='PASS' and (value['phase']!='complete' or not all(value[key] for key in needed)
            or counts[0]<3 or counts[1]!=1 or counts[4] or value['failed_line'] or value['denied_route']
            or value['shelf_books']<1 or value['profile_files_audited']<1
            or apply and (counts[2:4]!=[1,1] or statuses!=[200,200])):raise ValueError('membership_stage_incomplete')
    return value


def decode_stage(raw,apply):
    if not isinstance(raw,bytes) or len(raw)>2*1024*1024 or raw.count(FRAME)!=1:raise ValueError('membership_frame')
    value=json.loads(raw.split(FRAME)[1])
    if not isinstance(value,dict) or set(value)!={'report','private'}:raise ValueError('membership_envelope')
    validate_stage(value['report'],apply)
    private=value['private']
    if (not isinstance(private,dict) or set(private)!={'plan_fingerprint','intent_digest','final_members_digest'}
            or any(not isinstance(private[key],str) or not re.fullmatch('[a-f0-9]{64}',private[key]) for key in ('plan_fingerprint','final_members_digest'))
            or not isinstance(private['intent_digest'],str) or (not re.fullmatch('[a-f0-9]{64}',private['intent_digest']) if apply else private['intent_digest']!='')):
        raise ValueError('membership_receipt')
    return value


def decode_runner(raw,apply):
    if not isinstance(raw,bytes) or len(raw)>2*1024*1024 or raw.count(FRAME)!=1:raise ValueError('membership_runner_frame')
    value=json.loads(raw.split(FRAME)[1])
    if not isinstance(value,dict) or set(value)!={'report','private'}:raise ValueError('membership_runner_schema')
    report=value['report']
    if (not isinstance(report,dict) or set(report)!={'result','tmpfs_profile','profile_removed','runner_error','stage'}
            or not isinstance(report['result'],str) or report['result'] not in ('PASS','UNVERIFIED') or type(report['tmpfs_profile']) is not bool
            or type(report['profile_removed']) is not bool or not isinstance(report['runner_error'],str)
            or report['runner_error'] not in ERRORS):raise ValueError('membership_runner_types')
    if report['stage'] is None:
        if value['private'] is not None or report['result']!='UNVERIFIED':raise ValueError('membership_runner_empty')
    else:decode_stage(FRAME+json.dumps(dict(report=report['stage'],private=value['private'])).encode(),apply)
    if report['result']=='PASS' and (not report['tmpfs_profile'] or not report['profile_removed'] or report['runner_error']!='none'
                                    or report['stage']['result']!='PASS'):raise ValueError('membership_runner_unverified')
    return value
