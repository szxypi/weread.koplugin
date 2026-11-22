"""Independently read and verify one scoped ordinary reconnect state.

Only read requests are made by supplied clients. No write, credential refresh,
recovery, implicit retry or authority creation occurs here.
"""
import hashlib

from fetch_weread_epub import decode_content_shards,web_app_id
from readtime_upload_model import integer
from secure_ordinary_reconnect_trial import entered_point,validate_plan
from shelf_flag_change_contract import state_hash
from txt_full_summary import digest
from verify_eink_login import BASE as NATIVE
from verify_ordinary_reconnect_rpc_preview import native_snapshot, stable_shelf
from verify_position_roundtrip import same_position
from verify_reader_progress import find_node, project
from verify_web_source_progress import BASE as WEB


def scoped_shelf_equal(before,after,identity,expected=None):
    """Allow only the selected book's recent-read time and its list position to change."""
    if not isinstance(before,dict) or not isinstance(after,dict) or ('lectureSynckey' in before)!=('lectureSynckey' in after):return False
    if 'lectureSynckey' in before and (not integer(before['lectureSynckey'],0,2**53-1)
            or not integer(after['lectureSynckey'],0,2**53-1) or after['lectureSynckey']<before['lectureSynckey']):return False
    if ('synckey' in before)!=('synckey' in after):return False
    if 'synckey' in before and (not integer(before['synckey'],0,2**53-1)
            or not integer(after['synckey'],0,2**53-1) or after['synckey']<before['synckey']):return False
    def split(value):
        clean=stable_shelf(value);clean.pop('synckey',None);rows=clean.pop('books',None)
        progress_present='bookProgress' in clean;progress=clean.pop('bookProgress',None)
        if not isinstance(rows,list):raise ValueError('ordinary_trial/shelf')
        selected=[row for row in rows if isinstance(row,dict) and str(row.get('bookId'))==identity]
        if len(selected)!=1:raise ValueError('ordinary_trial/shelf')
        others=[row for row in rows if not (isinstance(row,dict) and str(row.get('bookId'))==identity)]
        target=dict(selected[0]);present='readUpdateTime' in target;stamp=target.pop('readUpdateTime',None)
        if present and not integer(stamp,0,2**53-1):raise ValueError('ordinary_trial/shelf')
        return clean,others,target,present,stamp,progress_present,progress
    def progress_equal(first,second):
        if first[5]!=second[5]:return False
        if not first[5]:return True
        a,b=first[6],second[6]
        if not isinstance(a,list) or not isinstance(b,list):return a==b
        ar=[row for row in a if isinstance(row,dict) and str(row.get('bookId'))==identity]
        br=[row for row in b if isinstance(row,dict) and str(row.get('bookId'))==identity]
        if not ar and not br:return a==b
        if len(ar)!=1 or len(br)!=1 or not isinstance(expected,dict):return False
        if ([row for row in a if not (isinstance(row,dict) and str(row.get('bookId'))==identity)]
                !=[row for row in b if not (isinstance(row,dict) and str(row.get('bookId'))==identity)]):return False
        left,right=ar[0],br[0];changed={'chapterUid','chapterIdx','chapterOffset','progress','appId','updateTime','synckey'}
        if set(left)!=set(right) or {k:v for k,v in left.items() if k not in changed}!={k:v for k,v in right.items() if k not in changed}:return False
        if (type(right.get('chapterUid')) not in (str,int) or type(right.get('chapterIdx')) is not int
                or type(right.get('chapterOffset')) is not int or type(right.get('progress')) not in (int,float)
                or str(right.get('chapterUid'))!=str(expected['chapter_uid']) or right.get('chapterIdx')!=expected['chapter_idx']
                or right.get('chapterOffset')!=expected['chapter_offset'] or right.get('progress')!=expected['raw_percent']):return False
        if left.get('appId')!=right.get('appId') and right.get('appId')!=web_app_id():return False
        for field in ('updateTime','synckey'):
            if field in left and (not integer(left[field],0,2**53-1) or not integer(right[field],0,2**53-1) or right[field]<left[field]):return False
        return True
    try:
        a=split(before);b=split(after)
        return (a[:4]==b[:4] and (not a[3] or b[4]>=a[4]) and progress_equal(a,b) and state_hash(before)==state_hash(after))
    except (ValueError,TypeError):return False


def capture_shelves(web,native,grant,plan,current):
    if current() is not True:raise ValueError('ordinary_trial/currentness')
    first=web.request('shelf',WEB+'/web/shelf/sync');second=native.request('ordinary_rpc_shelf',NATIVE+'/shelf/sync',credentials=grant)
    if (digest(stable_shelf(first))!=plan['web_shelf_sha256'] or digest(stable_shelf(second))!=plan['native_shelf_sha256']
            or current() is not True):raise ValueError('ordinary_trial/shelf')
    from copy import deepcopy
    return dict(web=deepcopy(first),native=deepcopy(second))


def check(web, native, grant, plan, expected, current, *, shelf_baselines=None, shelf_core_only=False):
    validate_plan(plan)
    if (type(shelf_core_only) is not bool or shelf_core_only and shelf_baselines is not None
            or not callable(current) or current() is not True or expected not in (plan['baseline'],entered_point(plan),plan['target'])
            or digest(web.vid)!=plan['owner_sha256'] or digest(grant)!=plan['grant_sha256']):
        raise ValueError('ordinary_trial/currentness')
    identity=plan['baseline']['book_id']
    web.verify_account();web.inspect(identity)
    if (web.book_id!=identity or not web.report.get('read_snapshot_consistent')
            or not same_position(project(web.raw_progress,identity),expected)
            or find_node(web.raw_progress,identity).get('summary')!=expected['summary']
            or digest(web.catalog)!=plan['catalog_sha256']):
        raise ValueError('ordinary_trial/web_state')
    source=decode_content_shards(*(web.shards[k] for k in ('e_0','e_1','e_3')))
    if hashlib.sha256(source.encode()).hexdigest()!=plan['source_sha256']:
        raise ValueError('ordinary_trial/source')
    observed=native_snapshot(native,grant,identity,expected)
    if observed['counts']!=plan['counts']:raise ValueError('ordinary_trial/counts')
    info=native.request('ordinary_rpc_info',NATIVE+'/book/info?bookId='+identity,credentials=grant)
    versions=[info[k] for k in ('bookVersion','version') if k in info]
    if (str(info.get('bookId'))!=identity or not versions
            or any(not integer(value,0,2147483647) or value!=plan['version'] for value in versions)):
        raise ValueError('ordinary_trial/version')
    web_shelf=web.request('shelf',WEB+'/web/shelf/sync')
    native_shelf=native.request('ordinary_rpc_shelf',NATIVE+'/shelf/sync',credentials=grant)
    if shelf_core_only:
        if ('web_shelf_core_sha256' not in plan or 'native_shelf_core_sha256' not in plan
                or state_hash(web_shelf)!=plan['web_shelf_core_sha256'] or state_hash(native_shelf)!=plan['native_shelf_core_sha256']):
            raise ValueError('ordinary_trial/shelf')
    elif shelf_baselines is None:
        if (digest(stable_shelf(web_shelf))!=plan['web_shelf_sha256']
                or digest(stable_shelf(native_shelf))!=plan['native_shelf_sha256']):raise ValueError('ordinary_trial/shelf')
    elif (not isinstance(shelf_baselines,dict) or set(shelf_baselines)!={'web','native'}
            or digest(stable_shelf(shelf_baselines['web']))!=plan['web_shelf_sha256']
            or digest(stable_shelf(shelf_baselines['native']))!=plan['native_shelf_sha256']
            or not scoped_shelf_equal(shelf_baselines['web'],web_shelf,identity,expected)
            or not scoped_shelf_equal(shelf_baselines['native'],native_shelf,identity,expected)):
        raise ValueError('ordinary_trial/shelf')
    if current() is not True:raise ValueError('ordinary_trial/currentness')
    return True
