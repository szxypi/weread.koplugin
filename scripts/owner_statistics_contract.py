"""Metadata-only boundaries for owner statistics UI acceptance."""
import json

FRAME=b'\nWEREAD_OWNER_STATISTICS_RESULT='
FLAGS={'anonymous_credentials','transport_guard_selftest','file_backed_sqlite','profile_matches','detail_views_match',
       'local_goal_readback','workers_reaped','credential_file_audit','native_filemanager_host','cache_account_scoped',
       'account_name_matches','account_name_glyphs'}
COUNTS={'profile_months':24,'validated_views':7,'detail_periods':6,'calendar_days':31,'calendar_cells':42,
        'profile_files_audited':512,'screenshots':1,'forbidden_requests':512,'failed_line':2000}
PHASES={'init','profile','monthly','history','return_month','weekly','annually','overall','audit','complete'}
ERRORS={'none','child_timeout','runner_exception','candidate_layout','input_limit','stage_unverified',
        'statistics_frame','statistics_schema','statistics_types','statistics_counts','statistics_requests','statistics_incomplete'}


def validate_stage(value,mode):
    if not isinstance(value,dict) or set(value)!=FLAGS|set(COUNTS)|{'result','mode','phase','request_counts','worker_http_child','account_name_present'}:
        raise ValueError('statistics_schema')
    if (type(value['result']) is not str or value['result'] not in {'PASS','UNVERIFIED'} or value['mode']!=mode
            or type(value['phase']) is not str or value['phase'] not in PHASES
            or any(type(value[k]) is not bool for k in FLAGS|{'worker_http_child','account_name_present'})):raise ValueError('statistics_types')
    if any(type(value[k]) is not int or not 0<=value[k]<=maximum for k,maximum in COUNTS.items()):raise ValueError('statistics_counts')
    counts=value['request_counts']
    if (not isinstance(counts,list) or not 1<=len(counts)<=29 or any(type(n) is not int or not 0<=n<=2 for n in counts)
            or sum(counts)>30 or mode=='reopen' and any(counts)):raise ValueError('statistics_requests')
    if value['result']=='PASS' and (value['phase']!='complete' or not all(value[k] for k in FLAGS)
            or value['screenshots'] or value['forbidden_requests'] or value['failed_line'] or not value['profile_files_audited']
            or not 1<=value['profile_months']<=24 or not 28<=value['calendar_days']<=31 or not 28<=value['calendar_cells']<=42 or value['validated_views']!=7
            or value['detail_periods']!=6 or value['worker_http_child']!=(mode=='live')
            or mode=='live' and sum(counts)!=value['profile_months']+6):raise ValueError('statistics_incomplete')
    return value


def decode_stage(raw,mode):
    if not isinstance(raw,bytes) or len(raw)>2*1024*1024 or raw.count(FRAME)!=1:raise ValueError('statistics_frame')
    return validate_stage(json.loads(raw.split(FRAME)[1]),mode)


def decode_runner(raw):
    if not isinstance(raw,bytes) or len(raw)>65536 or raw.count(FRAME)!=1:raise ValueError('statistics_frame')
    value=json.loads(raw.split(FRAME)[1])
    if (not isinstance(value,dict) or set(value)!={'result','tmpfs_profile','profile_removed','stages','runner_error','installed_files','installed_bytes_match'}
            or type(value['result']) is not str or value['result'] not in {'PASS','UNVERIFIED'}
            or type(value['tmpfs_profile']) is not bool or type(value['profile_removed']) is not bool
            or type(value['installed_files']) is not int or not 0<=value['installed_files']<=1000 or type(value['installed_bytes_match']) is not bool
            or not isinstance(value['stages'],list) or len(value['stages'])>2
            or type(value['runner_error']) is not str or value['runner_error'] not in ERRORS):raise ValueError('statistics_schema')
    for mode,stage in zip(('live','reopen'),value['stages']):validate_stage(stage,mode)
    if value['result']=='PASS' and (value['runner_error']!='none' or not value['tmpfs_profile'] or not value['profile_removed']
            or not value['installed_files'] or not value['installed_bytes_match']
            or len(value['stages'])!=2 or any(v['result']!='PASS' for v in value['stages'])
            or any(value['stages'][0][k]!=value['stages'][1][k] for k in ['profile_months','calendar_days','calendar_cells','validated_views','detail_periods','account_name_present'])
            or len(value['stages'][0]['request_counts'])!=len(value['stages'][1]['request_counts'])):raise ValueError('statistics_incomplete')
    return value
