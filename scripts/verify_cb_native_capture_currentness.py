#!/usr/bin/env python3
"""Read-only comparison of the saved CB capture to fresh account state."""
import argparse,json,resource

from cb_native_time_capture_bundle import store as capture_store
from secure_native_session import NativeSessionStore
from secure_weread_session import SessionStore
from txt_full_summary import digest
from verify_cb_native_time_capture import CaptureWeb,snapshot
from verify_native_txt_position import Native
from verify_translation_preflight import save_refreshed_web_session


def run(session,native_store,bundle):
    result=dict(result='UNVERIFIED',account_data_posts=0,authentication_posts=0,private_data_in_report=False)
    saved=grant=web=None
    try:
        captured,receipt=bundle.read()
        if not captured or not receipt:raise ValueError('cb_capture_current/missing')
        plan=captured['plan'];saved=session.load();grant=native_store.load(saved['vid'])
        if saved['vid']!=plan['owner'] or digest(grant['deviceId'])!=plan['device_sha256']:raise ValueError('cb_capture_current/owner')
        web=CaptureWeb();web.vid=saved['vid']
        for key,value in saved['cookies'].items():web.set_cookie(key,value)
        web.verify_account();web.allowed={plan['book_id']}
        web.request('shelf','https://weread.qq.com/web/shelf/sync')
        sample=web.inspect(plan['book_id']);web.verify_account()
        observed=snapshot(web,sample,Native(grant,plan['book_id']),grant)
        if (digest(observed)!=plan['baseline_sha256'] or observed['source']!=plan['raw_sha256']
                or observed['version']!=plan['book_version'] or sample['chapter_uid']!=plan['chapter_uid']):
            raise ValueError('cb_capture_current/changed')
        if bundle.read()!=(captured,receipt) or native_store.load(saved['vid'])!=grant:raise ValueError('cb_capture_current/changed')
        result.update(result='CB_CAPTURE_CURRENT',source_version_positions_counts_and_shelves_unchanged=True,
                      saved_capture_unchanged=True)
    except Exception:pass
    finally:
        if web:
            if saved and getattr(web,'authenticated',False):
                try:save_refreshed_web_session(session,saved,web)
                except Exception:result['result']='UNVERIFIED'
            web.samples.clear();web.progress.clear();web.catalogs.clear();web.close()
        for value in (saved,grant):
            if isinstance(value,dict):value.clear()
    return result


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--saved-capture',action='store_true');args=parser.parse_args(argv)
    if not args.saved_capture:
        print(json.dumps(dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0)));return 0
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    try:result=run(SessionStore(),NativeSessionStore(),capture_store())
    except Exception:result=dict(result='UNVERIFIED',account_data_posts=0,authentication_posts=0)
    print(json.dumps(result));return int(result['result']!='CB_CAPTURE_CURRENT')


if __name__=='__main__':raise SystemExit(main())
