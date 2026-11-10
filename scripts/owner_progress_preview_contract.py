"""Strict private real-reader upload preview. No write executor lives here."""
import json
import re

from verify_owner_reading import FRAME, RUNNER_ERRORS, decode_envelope
from verify_position_roundtrip import WRITE_ORDER, validate_payload

FLAGS = {'source_points_verified','reader_position_restored','source_upload_gate_preserved',
         'actual_upload_service','all_reports_unconfirmed','legacy_matches_source','page_start_matches_source'}
COUNTS = dict(captured_requests=4, synthetic_enter_acknowledgements=1, denied_requests=1024,
              network_write_dispatches=0, failed_line=10000)
ERRORS = {'progress_preview_schema','progress_preview_types','progress_preview_incomplete','progress_preview_private',
          'progress_preview_order','progress_preview_context','progress_preview_body','progress_preview_frame',
          'progress_preview_envelope','progress_preview_runner','progress_preview_clock','progress_preview_payload_count'}


def validate_addon(value, complete):
    if not isinstance(value,dict) or set(value) != FLAGS | set(COUNTS): raise ValueError('progress_preview_schema')
    if (any(type(value[k]) is not bool for k in FLAGS)
            or any(type(value[k]) is not int or not 0 <= value[k] <= n for k,n in COUNTS.items())):
        raise ValueError('progress_preview_types')
    if complete and (not all(value[k] for k in FLAGS-{'legacy_matches_source','page_start_matches_source'}) or value['captured_requests'] != 4
            or value['synthetic_enter_acknowledgements'] != 1 or value['denied_requests'] or value['failed_line']):
        raise ValueError('progress_preview_incomplete')


def private(value, complete):
    if not isinstance(value,dict) or set(value) != {'records'} or not isinstance(value['records'],list) or len(value['records']) > 4:
        raise ValueError('progress_preview_private')
    if complete and len(value['records']) != 4: raise ValueError('progress_preview_private')
    for index,record in enumerate(value['records']):
        if not isinstance(record,dict) or set(record) != {'stage','body','context'} or record['stage'] != WRITE_ORDER[index]:
            raise ValueError('progress_preview_order')
        context = record['context']
        if (not isinstance(context,dict) or set(context) != {'psvts','pclts','token'}
                or any(not isinstance(context[k],str) or not re.fullmatch(r'[!-~]{1,8192}',context[k]) for k in ('psvts','token'))
                or not (isinstance(context['pclts'],str) and re.fullmatch(r'[!-~]{1,8192}',context['pclts'])
                        or type(context['pclts']) is int and 1 <= context['pclts'] <= 9007199254740991)):
            raise ValueError('progress_preview_context')
        if not isinstance(record['body'],dict) or len(json.dumps(record['body']).encode()) > 16384:
            raise ValueError('progress_preview_body')


def decode(raw, owner, *, mode=None, full_chapters=1):
    if mode not in (None,'live') or full_chapters != 1 or not isinstance(raw,bytes) or len(raw) > 2*1024*1024 or raw.count(FRAME) != 1:
        raise ValueError('progress_preview_frame')
    value=json.loads(raw.split(FRAME)[1])
    if not isinstance(value,dict) or set(value) != {'report','cookies','progress_private'}:
        raise ValueError('progress_preview_envelope')
    report=value['report']
    if mode is None:
        if (not isinstance(report,dict) or set(report) != {'result','tmpfs_profile','profile_removed','stages','runner_error'}
                or report['result'] not in ('PASS','UNVERIFIED') or type(report['tmpfs_profile']) is not bool
                or type(report['profile_removed']) is not bool or report['runner_error'] not in RUNNER_ERRORS | ERRORS
                or not isinstance(report['stages'],list) or len(report['stages']) > 1):
            raise ValueError('progress_preview_runner')
        if report['result']=='PASS' and (not report['tmpfs_profile'] or not report['profile_removed'] or report['runner_error']!='none' or len(report['stages']) != 1):
            raise ValueError('progress_preview_runner')
        if not report['stages']:
            if report['result'] != 'UNVERIFIED' or value['progress_private'] is not None:raise ValueError('progress_preview_runner')
            from verify_owner_reading import validate_cookies
            validate_cookies(value['cookies'],owner)
            return value
        stage=report['stages'][0]
    else: stage=report
    addon=stage.pop('progress_preview')
    complete=stage.get('result')=='PASS'
    validate_addon(addon,complete)
    private(value['progress_private'],complete)
    decode_envelope(FRAME+json.dumps(dict(report=stage,cookies=value['cookies'])).encode(),owner,mode='live')
    stage['progress_preview']=addon
    if mode is None and report['result']=='PASS' and not complete: raise ValueError('progress_preview_incomplete')
    return value


def compare(records, plan, started_at, finished_at, *, allow_partial=False):
    if len(records)>4 or not allow_partial and len(records)!=4: raise ValueError('progress_preview_payload_count')
    for stage,record in zip(WRITE_ORDER,records):
        if record['stage'] != stage:raise ValueError('progress_preview_order')
        body,context=record['body'],record['context']
        ct=body.get('ct')
        if type(ct) is not int or not started_at-1 <= ct <= finished_at+1:
            raise ValueError('progress_preview_clock')
        if body.get('ps') != context['psvts'] or body.get('pc') != context['pclts']:
            raise ValueError('progress_preview_context')
        native_plan=dict(plan,context=context,pclts=context['pclts'])
        validate_payload(native_plan,record['stage'],body,observed_at=ct)

