"""Independently read and verify one scoped ordinary reconnect state.

Only read requests are made by supplied clients. No write, credential refresh,
recovery, implicit retry or authority creation occurs here.
"""
import hashlib

from fetch_weread_epub import decode_content_shards
from readtime_upload_model import integer
from secure_ordinary_reconnect_trial import validate_plan
from txt_full_summary import digest
from verify_eink_login import BASE as NATIVE
from verify_ordinary_reconnect_rpc_preview import native_snapshot, stable_shelf
from verify_position_roundtrip import same_position
from verify_reader_progress import find_node, project
from verify_web_source_progress import BASE as WEB


def check(web, native, grant, plan, expected, current):
    validate_plan(plan)
    if (not callable(current) or current() is not True or expected not in (plan['baseline'],plan['target'])
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
    if (digest(stable_shelf(web_shelf))!=plan['web_shelf_sha256']
            or digest(stable_shelf(native_shelf))!=plan['native_shelf_sha256']):
        raise ValueError('ordinary_trial/shelf')
    if current() is not True:raise ValueError('ordinary_trial/currentness')
    return True
