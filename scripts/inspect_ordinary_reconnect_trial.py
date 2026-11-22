#!/usr/bin/env python3
"""Fresh-process read-only inspection of a retired ordinary reconnect trial."""
import argparse
from datetime import datetime,timezone
import json
import resource

from ordinary_reconnect_observe import check
from secure_native_session import NativeSessionStore
from secure_ordinary_reconnect_trial import OrdinaryReconnectStore,OrdinaryReconnectRetryStore,OrdinaryReconnectThirdStore
from secure_weread_session import COOKIE_NAMES,SessionStore
from txt_full_summary import digest
from verify_native_txt_position import Native
from verify_ordinary_reconnect_preview import CapturedPreflight
from verify_translation_preflight import save_refreshed_web_session


class Reads(Native):max_reads=32


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--saved-session',action='store_true')
    scope=p.add_mutually_exclusive_group();scope.add_argument('--retry',action='store_true');scope.add_argument('--third',action='store_true');a=p.parse_args(argv)
    scoped=a.retry or a.third
    if scoped and not a.saved_session:p.error('separate scope requires saved session')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,
                authentication_posts=0,private_data_on_regular_disk=False)
    saved=grant=web=None
    try:
        if a.saved_session:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0))
            from verify_native_thought_trial import other_pending
            journal=(OrdinaryReconnectThirdStore if a.third else OrdinaryReconnectRetryStore if a.retry else OrdinaryReconnectStore)();state,_=journal.read()
            if (not state or state['phase']!='retired' or state['posts']!=3
                    or other_pending(exclude_ordinary_reconnect_trial=not scoped,exclude_ordinary_reconnect_retry=a.retry,exclude_ordinary_reconnect_third=a.third)):
                raise ValueError('ordinary_inspect/intent')
            plan=state['plan'];store=SessionStore();saved=store.load();grant=NativeSessionStore().load(saved['vid'])
            if digest(saved)!=plan['web_session_sha256'] or digest(grant)!=plan['grant_sha256'] or digest(saved['vid'])!=plan['owner_sha256']:
                raise ValueError('ordinary_inspect/session')
            web=CapturedPreflight();web.vid=saved['vid']
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account();native=Reads(grant,plan['baseline']['book_id'])
            def current():
                cookies={cookie.name:cookie.value for cookie in web.cookies if cookie.name in COOKIE_NAMES
                         and cookie.domain in ('.weread.qq.com','weread.qq.com') and cookie.path=='/'}
                return (store.load()==saved and NativeSessionStore().load(saved['vid'])==grant and cookies==saved['cookies']
                        and not other_pending(exclude_ordinary_reconnect_trial=not scoped,exclude_ordinary_reconnect_retry=a.retry,exclude_ordinary_reconnect_third=a.third))
            for _ in range(2):check(web,native,grant,plan,plan['baseline'],current,shelf_core_only=scoped)
            web.verify_account();save_refreshed_web_session(store,saved,web)
            report.update(result='ORDINARY_RECONNECT_INDEPENDENT_READBACK_VERIFIED',independent_readbacks=2,
                          original_position_and_summary=True,time_counts_unchanged=True,source_catalog_shelf_fields_checked=True,
                          shelf_check='core_only' if scoped else 'stable_fields',no_automatic_replay=True)
    except Exception as error:
        report['result']='UNVERIFIED'
        if isinstance(error,ValueError) and str(error) in {'ordinary_inspect/intent','ordinary_inspect/session'}:report['reason']=str(error)
    finally:
        if web:
            if web.authenticated:
                try:web.verify_account();save_refreshed_web_session(store,store.load(),web)
                except Exception:report['result']='UNVERIFIED';report['reason']='ordinary_inspect/session'
            web.shards.clear();web.close()
        for value in (saved,grant):
            if isinstance(value,dict):value.clear()
    print(json.dumps(report,indent=2));return int(report['result']=='UNVERIFIED')

if __name__=='__main__':raise SystemExit(main())
