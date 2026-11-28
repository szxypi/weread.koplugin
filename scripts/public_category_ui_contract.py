"""Strict public-only reports and same-response native book-list comparison."""
import json
from verify_category_books import page
from verify_category_catalog import project as catalog

FRAME=b'\nWEREAD_PUBLIC_CATEGORY_RESULT='
PRIVATE=b'\nWEREAD_PUBLIC_CATEGORY_PRIVATE='
FLAGS={'native_filemanager_host','guest','transport_guard_selftest','file_backed_sqlite','directory_persisted',
       'cache_projected','all_pages_verified','workers_reaped','profile_audit','stale_picker_rejected','public_store_rejects_personal'}
COUNTS={'batch_views':16,'painted_views':256,'forward_books':2000,'profile_files':64,'failed_line':4000,'forbidden_requests':32}
ERRORS={'none','input_limit','candidate_layout','child_timeout','runner_exception','stage_unverified','category_ui_schema'}


def stage(value,mode,requests):
    if not isinstance(value,dict) or set(value)!=FLAGS|set(COUNTS)|{'result','mode','phase','request_counts'}:raise ValueError('category_ui_schema')
    if (value['result'] not in ('PASS','UNVERIFIED') or value['mode']!=mode
            or value['phase'] not in ('init','catalog','rank','main','child','audit','complete')
            or any(type(value[k]) is not bool for k in FLAGS)
            or any(type(value[k]) is not int or not 0<=value[k]<=limit for k,limit in COUNTS.items())
            or not isinstance(value['request_counts'],list) or len(value['request_counts']) not in (0,requests)
            or any(type(n) is not int or not 0<=n<=1 for n in value['request_counts'])):raise ValueError('category_ui_schema')
    if value['result']=='PASS' and (not all(value[k] for k in FLAGS) or value['phase']!='complete'
            or value['failed_line'] or value['forbidden_requests'] or value['batch_views']<3
            or value['painted_views']<value['batch_views'] or value['profile_files']<1
            or value['request_counts']!=[int(mode=='live')]*requests):raise ValueError('category_ui_schema')
    return value


def decode_stage(raw,mode,requests):
    if type(raw) is not bytes or len(raw)>8*1024*1024 or raw.count(PRIVATE)!=1 or raw.count(FRAME)!=1:raise ValueError('category_ui_schema')
    public=stage(json.loads(raw.split(FRAME)[1]),mode,requests)
    private=json.loads(raw.split(PRIVATE)[1].split(FRAME)[0])
    return public,private


def decode_runner(raw,requests):
    if type(raw) is not bytes or len(raw)>8*1024*1024 or raw.count(PRIVATE)!=1 or raw.count(FRAME)!=1:raise ValueError('category_ui_schema')
    report=json.loads(raw.split(FRAME)[1])
    fields={'result','tmpfs_profile','profile_removed','installed_bytes_match','installed_files','stages','runner_error'}
    if (not isinstance(report,dict) or set(report)!=fields or report['result'] not in ('PASS','UNVERIFIED') or report['runner_error'] not in ERRORS
            or any(type(report[k]) is not bool for k in ('tmpfs_profile','profile_removed','installed_bytes_match'))
            or type(report['installed_files']) is not int or not 0<=report['installed_files']<=1000
            or not isinstance(report['stages'],list) or len(report['stages'])>2):
        raise ValueError('category_ui_schema')
    for mode,row in zip(('live','reopen'),report['stages']):stage(row,mode,requests)
    return report


def compare_runner(raw,payload):
    report=decode_runner(raw,len(payload['samples'])+1)
    private=json.loads(raw.split(PRIVATE)[1].split(FRAME)[0])
    if (report['result']!='PASS' or report['runner_error']!='none' or len(report['stages'])!=2
            or any(report[k] is not True for k in ('tmpfs_profile','profile_removed','installed_bytes_match'))
            or report['installed_files']<1 or not isinstance(private,list) or len(private)!=2):raise ValueError('category_ui_schema')
    samples=payload['samples'];planned=[(row['role'],row['cursor']) for row in samples];models={}
    for index,mode in enumerate(('live','reopen')):
        proof=stage(report['stages'][index],mode,len(samples)+1);data=private[index]
        if proof['result']!='PASS':raise ValueError('category_ui_schema')
        if not isinstance(data,dict) or set(data)!={'catalog_source','sources','views'}:raise ValueError('category_ui_schema')
        if not isinstance(data['sources'],list) or not isinstance(data['views'],list):raise ValueError('category_ui_schema')
        if index==0:
            if catalog(data['catalog_source'],payload['catalog']['loaded_at'])!=payload['catalog'] or len(data['sources'])!=len(planned):
                raise ValueError('category_ui_schema')
            for source,key in zip(data['sources'],planned):
                if not isinstance(source,dict) or set(source)!={'role','cursor','source'} or (source['role'],source['cursor'])!=key:
                    raise ValueError('category_ui_schema')
                models[key]=page(source['source'],source['cursor'])
        elif data['sources'] or data['catalog_source'] is not None:raise ValueError('category_ui_schema')
        views=planned if index==0 else [planned[-1]]+[
            key for pair in planned for key in ([pair,(pair[0],0)] if pair[1]>0 else [pair])]
        if proof['batch_views']!=len(views) or len(data['views'])!=len(views):raise ValueError('category_ui_schema')
        forward=0
        for value,key in zip(data['views'],views):
            if not isinstance(value,dict) or set(value)!={'role','cursor','books','next_cursor','has_more','cached'}:
                raise ValueError('category_ui_schema')
            expected=dict(models[key],role=key[0],cursor=key[1],cached=index==1)
            if index:expected['has_more']=expected['has_more'] and (key[0],expected['next_cursor']) in models
            if value!=expected:raise ValueError('category_ui_schema')
            forward+=len(expected['books'])
        if proof['forward_books']!=forward:raise ValueError('category_ui_schema')
    for (role,cursor),model in models.items():
        if cursor and {b['bookId'] for b in model['books']} & {b['bookId'] for b in models[role,0]['books']}:
            raise ValueError('category_ui_schema')
    return report
