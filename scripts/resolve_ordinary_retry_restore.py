#!/usr/bin/env python3
"""Resolve an uncertain retry at its original position by reads; never sends POSTs."""
import argparse
import hashlib
import json
import re
import resource

from ordinary_partial_recovery import checked_pair,verified_grant
from secure_native_session import NativeSessionStore
from secure_ordinary_reconnect_trial import OrdinaryReconnectRetryStore,OrdinaryReconnectThirdStore,OrdinaryReconnectFourthStore
from secure_ordinary_recovery_renewal import RetryRecoveryRenewalStore,ThirdRecoveryRenewalStore,FourthRecoveryRenewalStore
from secure_ordinary_restore_readback import RestoreReadbackStore,ThirdRestoreReadbackStore,FourthRestoreReadbackStore
from secure_weread_session import COOKIE_NAMES,SessionStore
from shelf_flag_change_contract import state_hash
from txt_full_summary import digest
from verify_native_txt_position import Native
from verify_ordinary_reconnect_preview import CapturedPreflight
from verify_translation_preflight import save_refreshed_web_session


class Reads(Native):max_reads=32


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--saved-session',action='store_true');p.add_argument('--resolve',action='store_true')
    scope=p.add_mutually_exclusive_group();scope.add_argument('--third',action='store_true');scope.add_argument('--fourth',action='store_true');a=p.parse_args(argv)
    if a.saved_session!=a.resolve:p.error('pair saved session and read-only resolution')
    if (a.third or a.fourth) and not a.saved_session:p.error('separate scope requires saved session')
    report=dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts=0,private_data_on_regular_disk=False,
                original_trial_verified=False,restore_replayed=False)
    saved=grant=web=None;private=set()
    try:
        if a.saved_session:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0))
            from verify_native_thought_trial import other_pending
            original=(OrdinaryReconnectFourthStore if a.fourth else OrdinaryReconnectThirdStore if a.third else OrdinaryReconnectRetryStore)();state,receipt=original.read()
            bridge=(FourthRecoveryRenewalStore if a.fourth else ThirdRecoveryRenewalStore if a.third else RetryRecoveryRenewalStore)();bs,br=bridge.read()
            proof=(FourthRestoreReadbackStore if a.fourth else ThirdRestoreReadbackStore if a.third else RestoreReadbackStore)();proof_state,_=proof.read()
            allowed=('enter_pending','enter_acknowledged','enter_verified','position_pending','position_acknowledged','position_verified',
                     'restore_pending','restore_acknowledged')
            if (not state or state['phase'] not in allowed
                    or not receipt or other_pending(exclude_ordinary_reconnect_retry=not (a.third or a.fourth),exclude_ordinary_reconnect_third=a.third,exclude_ordinary_reconnect_fourth=a.fourth)):
                raise ValueError('ordinary_restore_readback/intent')
            plan=state['plan'];session=SessionStore();saved=session.load();grant=NativeSessionStore().load(saved['vid'])
            if digest(saved)!=plan['web_session_sha256']:raise ValueError('ordinary_restore_readback/session')
            grant_sha,bridge_sha=verified_grant(plan,receipt,saved,grant,bs,br)
            private.update(str(v) for v in saved['cookies'].values());private.update(str(v) for v in grant.values() if isinstance(v,str))
            private.update((plan['baseline']['book_id'],plan['baseline']['summary'],plan['target']['summary']))
            web=CapturedPreflight();web.vid=saved['vid']
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account();native=Reads(grant,plan['baseline']['book_id'])
            def current():
                cookies={c.name:c.value for c in web.cookies if c.name in COOKIE_NAMES and c.domain in ('.weread.qq.com','weread.qq.com') and c.path=='/'}
                return (original.read()==(state,receipt) and bridge.read()==(bs,br) and session.load()==saved
                        and NativeSessionStore().load(saved['vid'])==grant and cookies==saved['cookies']
                        and not other_pending(exclude_ordinary_reconnect_retry=not (a.third or a.fourth),exclude_ordinary_reconnect_third=a.third,exclude_ordinary_reconnect_fourth=a.fourth))
            sample=checked_pair(web,native,grant,plan,plan['baseline'],current,grant_sha)
            if (state_hash(sample['web_shelf'])!=plan['web_shelf_core_sha256']
                    or state_hash(sample['native_shelf'])!=plan['native_shelf_core_sha256']):raise ValueError('ordinary_restore_readback/shelf')
            bound=dict(original_intent_sha256=hashlib.sha256(receipt.pending).hexdigest(),owner_sha256=plan['owner_sha256'],
                native_grant_sha256=grant_sha,renewal_bridge_sha256=bridge_sha,source_sha256=plan['source_sha256'],
                catalog_sha256=plan['catalog_sha256'],web_shelf_core_sha256=plan['web_shelf_core_sha256'],
                native_shelf_core_sha256=plan['native_shelf_core_sha256'])
            if current() is not True:raise ValueError('ordinary_restore_readback/session')
            if proof_state is None:proof.record(bound)
            elif proof_state['binding']!=bound:raise ValueError('ordinary_restore_readback/intent')
            confirmation=checked_pair(web,native,grant,plan,plan['baseline'],current,grant_sha)
            if (state_hash(confirmation['web_shelf'])!=plan['web_shelf_core_sha256']
                    or state_hash(confirmation['native_shelf'])!=plan['native_shelf_core_sha256'] or current() is not True):
                raise ValueError('ordinary_restore_readback/shelf')
            original.close_after_restore_readback(receipt,proof,bridge)
            report.update(result='ORDINARY_RESTORE_READBACK_RESOLVED',independent_readbacks=4,original_position_and_summary=True,
                          time_counts_unchanged=True,source_catalog_and_shelf_core_checked=True,no_automatic_replay=True)
    except Exception as error:
        report['result']='UNVERIFIED'
        if isinstance(error,ValueError) and re.fullmatch(r'ordinary_restore_readback/[a-z_]+',str(error)):report['reason']=str(error)
    finally:
        if web:
            if web.authenticated:
                try:web.verify_account();save_refreshed_web_session(session,session.load(),web)
                except Exception:report['result']='UNVERIFIED';report['reason']='ordinary_restore_readback/session'
            web.shards.clear();web.close()
        for value in (saved,grant):
            if isinstance(value,dict):value.clear()
    encoded=json.dumps(report,ensure_ascii=True)
    if any(len(v)>=8 and (v in encoded or json.dumps(v,ensure_ascii=True)[1:-1] in encoded) for v in private):
        report=dict(result='UNVERIFIED',reason='ordinary_restore_readback/privacy',account_data_posts=0,authentication_posts=0)
    print(json.dumps(report,indent=2));return int(report['result']=='UNVERIFIED')

if __name__=='__main__':raise SystemExit(main())
