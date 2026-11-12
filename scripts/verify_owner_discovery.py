#!/usr/bin/env python3
"""Opt-in owner bookstore pages and fresh-process offline batches; GET only."""
import argparse
from datetime import datetime,timezone
import json
import subprocess
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from verify_native_discovery import DiscoveryProbe,page

FRAME=b'\nWEREAD_OWNER_DISCOVERY_RESULT='
PRIVATE_FRAME=b'\nWEREAD_OWNER_DISCOVERY_PRIVATE='
FLAGS={'anonymous_credentials','transport_guard_selftest','file_backed_sqlite','ui_projection_matches',
       'workers_reaped','credential_file_audit','native_filemanager_host','cache_account_scoped','cache_session_free','pagination_matches'}
COUNTS={'validated_views':10,'samples':6,'profile_files_audited':512,'screenshots':0,'forbidden_requests':512,'failed_line':2000}
PHASES={'init','search','similar','recommend','audit','complete'}
ERRORS={'none','child_timeout','runner_exception','candidate_layout','input_limit','stage_unverified','discovery_schema'}


def stage(value,mode):
    if not isinstance(value,dict) or set(value)!=FLAGS|set(COUNTS)|{'result','mode','phase','request_counts','worker_http_child','batch_sizes'}:raise ValueError('discovery_schema')
    if (type(value['result']) is not str or value['result'] not in ('PASS','UNVERIFIED') or value['mode']!=mode or type(value['phase']) is not str or value['phase'] not in PHASES
            or any(type(value[k]) is not bool for k in FLAGS|{'worker_http_child'})
            or any(type(value[k]) is not int or not 0<=value[k]<=maximum for k,maximum in COUNTS.items())):raise ValueError('discovery_schema')
    for key,limit in [('request_counts',1),('batch_sizes',100)]:
        rows=value[key]
        if not isinstance(rows,list) or not 0<=len(rows)<=6 or any(type(n) is not int or not 0<=n<=limit for n in rows):raise ValueError('discovery_schema')
    if mode=='reopen' and any(value['request_counts']):raise ValueError('discovery_schema')
    if value['result']=='PASS' and (not 3<=len(value['request_counts'])<=6 or len(value['batch_sizes'])!=len(value['request_counts']) or value['phase']!='complete' or not all(value[k] for k in FLAGS) or value['forbidden_requests']
            or value['failed_line'] or value['samples']!=len(value['batch_sizes']) or value['profile_files_audited']<1
            or value['worker_http_child']!=(mode=='live') or value['validated_views']!=(value['samples'] if mode=='live' else 2*value['samples']-2)
            or mode=='live' and value['request_counts']!=[1]*value['samples']):raise ValueError('discovery_schema')
    return value


def decode_stage(raw,mode):
    if type(raw) is not bytes or len(raw)>2*1024*1024 or raw.count(FRAME)!=1:raise ValueError('discovery_schema')
    return stage(json.loads(raw.split(FRAME)[1]),mode)


def decode_runner(raw):
    if type(raw) is not bytes or len(raw)>65536 or raw.count(FRAME)!=1:raise ValueError('discovery_schema')
    value=json.loads(raw.split(FRAME)[1])
    if (not isinstance(value,dict) or set(value)!={'result','tmpfs_profile','profile_removed','installed_bytes_match','installed_files','stages','runner_error'}
            or type(value['result']) is not str or value['result'] not in ('PASS','UNVERIFIED') or type(value['tmpfs_profile']) is not bool
            or type(value['installed_bytes_match']) is not bool or type(value['installed_files']) is not int or not 0<=value['installed_files']<=1000
            or type(value['profile_removed']) is not bool or type(value['runner_error']) is not str or value['runner_error'] not in ERRORS
            or not isinstance(value['stages'],list) or len(value['stages'])>2):raise ValueError('discovery_schema')
    for mode,row in zip(('live','reopen'),value['stages']):stage(row,mode)
    if value['result']=='PASS' and (value['runner_error']!='none' or not value['tmpfs_profile'] or not value['profile_removed']
            or not value['installed_bytes_match'] or value['installed_files']<1 or len(value['stages'])!=2 or any(row['result']!='PASS' for row in value['stages'])
            or value['stages'][0]['batch_sizes']!=value['stages'][1]['batch_sizes']):raise ValueError('discovery_schema')
    return value



def private_output(raw):
    if type(raw) is not bytes or len(raw)>4*1024*1024 or raw.count(PRIVATE_FRAME)!=1 or raw.count(FRAME)!=1:raise ValueError('discovery_schema')
    prefix,metadata=raw.split(FRAME)
    private=json.loads(prefix.split(PRIVATE_FRAME)[1]);ui=decode_runner(FRAME+metadata)
    if not isinstance(private,list) or len(private)!=2:raise ValueError('discovery_schema')
    return ui,private


def compare_private(private,planned):
    models={}
    for index,entry in enumerate(private):
        if not isinstance(entry,dict) or set(entry)!={'sources','views'}:raise ValueError('discovery_schema')
        if not isinstance(entry['sources'],list) or not isinstance(entry['views'],list):raise ValueError('discovery_schema')
        if index==0:
            if len(entry['sources'])!=len(planned):raise ValueError('discovery_schema')
            for source,plan in zip(entry['sources'],planned):
                if set(source)!={'kind','cursor','source'} or (source['kind'],source['cursor'])!=(plan['kind'],plan['cursor']):raise ValueError('discovery_schema')
                model=page(source['kind'],source['source'],source['cursor'])
                for book in model['books']:
                    if book.get('searchIdx') is None:book.pop('searchIdx',None)
                models[source['kind'],source['cursor']]=model
        elif entry['sources']:raise ValueError('discovery_schema')
        expected_views=[(row['kind'],row['cursor']) for row in planned]
        if index:
            expected_views=[expected_views[-1]]
            for row in planned:
                expected_views.append((row['kind'],row['cursor']))
                if row['cursor']>0:expected_views.append((row['kind'],0))
        if len(entry['views'])!=len(expected_views):raise ValueError('discovery_schema')
        for view,expected_view in zip(entry['views'],expected_views):
            if not isinstance(view,dict) or set(view)!={'kind','cursor','books','next_cursor','has_more','cached'}:raise ValueError('discovery_schema')
            if (view['kind'],view['cursor'])!=expected_view:raise ValueError('discovery_schema')
            model=models.get((view['kind'],view['cursor']))
            if not model or view['cached']!=(index==1) or view['books']!=model['books'] or view['next_cursor']!=model['next_cursor']:raise ValueError('discovery_schema')
            more=model['has_more'] and (index==0 or (view['kind'],view['next_cursor']) in models)
            if view['has_more']!=more:raise ValueError('discovery_schema')
    for (kind,cursor),model in models.items():
        if not cursor:continue
        first=models[kind,0]
        if {b['bookId'] for b in first['books']} & {b['bookId'] for b in model['books']}:raise ValueError('discovery_schema')
        if kind=='similar' and (not first.get('session_id') or first.get('session_id')!=model.get('session_id')):raise ValueError('discovery_schema')
    return True


def prepare(credentials,probe):
    baseline=probe.inspect(credentials);samples=[]
    for kind in ['search','similar','recommend']:
        for row in probe.samples:
            if row['kind']!=kind:continue
            expected=dict(row['expected']);expected.pop('session_id',None)
            for book in expected['books']:
                if book.get('searchIdx') is None:book.pop('searchIdx',None)
            samples.append(dict(kind=kind,cursor=row['cursor'],expected=expected))
    return dict(credentials=credentials,book_id=probe.target,book_title='Saved book',keyword='三体',samples=samples),baseline


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-session',action='store_true');parser.add_argument('--lua-command',nargs=argparse.REMAINDER)
    args=parser.parse_args(argv)
    if bool(args.saved_session)!=bool(args.lua_command):parser.error('pair --saved-session and --lua-command; put --lua-command last')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts_attempted=0,
                authentication_posts_attempted=0,screenshots=0,private_data_on_regular_disk=False,credentials_written_to_files=False)
    credentials=payload=probe=None
    try:
        if args.saved_session:
            credentials=NativeSessionStore().load(SessionStore().load()['vid']);probe=DiscoveryProbe();payload,_baseline=prepare(credentials,probe)
            raw=json.dumps(payload,ensure_ascii=False).encode()
            if len(raw)>2*1024*1024:raise ValueError('input_limit')
            child=subprocess.run(args.lua_command,input=raw,capture_output=True,timeout=320)
            value,private=private_output(child.stdout);report['ui']=value
            if child.returncode or value['result']!='PASS' or value['stages'][0]['batch_sizes']!=[len(row['expected']['books']) for row in payload['samples']]:raise ValueError('stage_unverified')
            compare_private(private,payload['samples'])
            report.update(result='OWNER_DISCOVERY_FILE_UI_AND_OFFLINE_VERIFIED',same_owner_verified=True,same_response_python_projection_matches=True,python_preflight_gets=len(probe.report['stages']))
    except Exception:report.update(result='UNVERIFIED',reason='owner_discovery_unverified')
    finally:
        if credentials:credentials.clear()
        if payload:payload.clear()
        if probe:report['preflight_stages']=[{k:v for k,v in row.items() if k in ('stage','status','error_code')} for row in probe.report['stages']];probe.samples.clear()
    print(json.dumps(report,ensure_ascii=False,indent=2));return 0 if report['result'] in ('OFFLINE_ONLY','OWNER_DISCOVERY_FILE_UI_AND_OFFLINE_VERIFIED') else 1


if __name__=='__main__':raise SystemExit(main())
