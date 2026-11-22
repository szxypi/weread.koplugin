#!/usr/bin/env python3
"""Fresh-process read-only inspection of one completed partial recovery."""
import argparse
from copy import deepcopy
from datetime import datetime,timezone
import hashlib
import json
import resource

from ordinary_partial_recovery import checked_pair,verified_grant
from secure_native_session import NativeSessionStore
from secure_ordinary_partial_recovery import PartialRecoveryStore,RetryPartialRecoveryStore,ThirdPartialRecoveryStore
from secure_ordinary_reconnect_trial import OrdinaryReconnectStore,OrdinaryReconnectRetryStore,OrdinaryReconnectThirdStore,PHASES
from secure_ordinary_recovery_renewal import RecoveryRenewalStore,RetryRecoveryRenewalStore,ThirdRecoveryRenewalStore
from secure_shelf_experiment import Receipt,canonical
from secure_weread_session import COOKIE_NAMES,SessionStore
from shelf_flag_change_contract import state_hash
from txt_full_summary import digest
from verify_native_txt_position import Native
from verify_ordinary_reconnect_preview import CapturedPreflight
from verify_ordinary_reconnect_rpc_preview import stable_shelf
from verify_translation_preflight import save_refreshed_web_session


class Reads(Native):max_reads=32


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--saved-session',action='store_true')
    scope=p.add_mutually_exclusive_group();scope.add_argument('--retry',action='store_true');scope.add_argument('--third',action='store_true');a=p.parse_args(argv)
    scoped=a.retry or a.third
    if scoped and not a.saved_session:p.error('separate scope requires saved session')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,
                authentication_posts=0,private_data_on_regular_disk=False,original_trial_verified=False)
    saved=grant=web=None;private=set()
    try:
        if a.saved_session:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0))
            from verify_native_thought_trial import other_pending
            original=(OrdinaryReconnectThirdStore if a.third else OrdinaryReconnectRetryStore if a.retry else OrdinaryReconnectStore)();state,original_receipt=original.read()
            recovery=(ThirdPartialRecoveryStore if a.third else RetryPartialRecoveryStore if a.retry else PartialRecoveryStore)();recovered,recovery_receipt=recovery.read()
            bridge=(ThirdRecoveryRenewalStore if a.third else RetryRecoveryRenewalStore if a.retry else RecoveryRenewalStore)();bridge_state,bridge_receipt=bridge.read()
            if (not state or state['phase'] not in (('partial_restored','partial_restored_after_position') if scoped else ('partial_restored',)) or not recovered
                    or recovered['phase']!='retired' or recovered['posts']!=1
                    or other_pending(exclude_ordinary_reconnect_trial=not scoped,exclude_ordinary_reconnect_retry=a.retry,exclude_ordinary_reconnect_third=a.third)):
                raise ValueError('ordinary_partial_inspect/intent')
            previous=deepcopy(state);previous['phase']=recovered['binding']['original_phase'] if scoped else 'enter_acknowledged'
            previous['posts']=PHASES[previous['phase']]
            if previous['posts']!=state['posts']:raise ValueError('ordinary_partial_inspect/intent')
            previous_receipt=Receipt(canonical(previous));bound=recovered['binding']
            if hashlib.sha256(previous_receipt.pending).hexdigest()!=bound['original_intent_sha256']:
                raise ValueError('ordinary_partial_inspect/intent')
            plan=state['plan'];store=SessionStore();saved=store.load();grant=NativeSessionStore().load(saved['vid'])
            if digest(saved)!=plan['web_session_sha256']:raise ValueError('ordinary_partial_inspect/session')
            grant_sha,bridge_sha=verified_grant(plan,previous_receipt,saved,grant,bridge_state,bridge_receipt)
            if grant_sha!=bound['native_grant_sha256'] or bridge_sha!=bound['renewal_bridge_sha256']:
                raise ValueError('ordinary_partial_inspect/session')
            private.update(str(v) for v in saved['cookies'].values());private.update(str(v) for v in grant.values() if isinstance(v,str))
            private.update((plan['baseline']['book_id'],plan['baseline']['summary'],plan['target']['summary']))
            web=CapturedPreflight();web.vid=saved['vid']
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account();native=Reads(grant,plan['baseline']['book_id'])
            def current():
                cookies={cookie.name:cookie.value for cookie in web.cookies if cookie.name in COOKIE_NAMES
                         and cookie.domain in ('.weread.qq.com','weread.qq.com') and cookie.path=='/'}
                return (original.read()==(state,original_receipt) and recovery.read()==(recovered,recovery_receipt)
                        and bridge.read()==(bridge_state,bridge_receipt) and store.load()==saved
                        and NativeSessionStore().load(saved['vid'])==grant and cookies==saved['cookies']
                        and not other_pending(exclude_ordinary_reconnect_trial=not scoped,exclude_ordinary_reconnect_retry=a.retry,exclude_ordinary_reconnect_third=a.third))
            after=checked_pair(web,native,grant,plan,plan['baseline'],current,grant_sha)
            if (state_hash(after['web_shelf'])!=bound['web_shelf_core_sha256']
                    or state_hash(after['native_shelf'])!=bound['native_shelf_core_sha256']):
                raise ValueError('ordinary_partial_inspect/shelf')
            report.update(result='ORDINARY_PARTIAL_RECOVERY_INDEPENDENT_READBACK_VERIFIED',independent_readbacks=2,
                          original_position_and_summary=True,time_counts_unchanged=True,source_catalog_and_shelf_core_checked=True,
                          web_shelf_stable_fields_match_pre_restore=digest(stable_shelf(after['web_shelf']))==bound['web_shelf_sha256'],
                          native_shelf_stable_fields_match_pre_restore=digest(stable_shelf(after['native_shelf']))==bound['native_shelf_sha256'],
                          no_automatic_replay=True)
    except Exception as error:
        report['result']='UNVERIFIED'
        if isinstance(error,ValueError) and str(error) in {'ordinary_partial_inspect/intent','ordinary_partial_inspect/session','ordinary_partial_inspect/shelf'}:report['reason']=str(error)
    finally:
        if web:
            if web.authenticated:
                try:web.verify_account();save_refreshed_web_session(store,store.load(),web)
                except Exception:report['result']='UNVERIFIED';report['reason']='ordinary_partial_inspect/session'
            web.shards.clear();web.close()
        for value in (saved,grant):
            if isinstance(value,dict):value.clear()
    encoded=json.dumps(report,ensure_ascii=True)
    if any(len(value)>=8 and (value in encoded or json.dumps(value,ensure_ascii=True)[1:-1] in encoded) for value in private):
        report=dict(result='UNVERIFIED',reason='ordinary_partial_inspect/privacy',account_data_posts=0,authentication_posts=0)
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')

if __name__=='__main__':raise SystemExit(main())
