#!/usr/bin/env python3
"""One guarded native renewal bound to a partially verified ordinary trial.

Two fresh 401 reads are required before one authentication POST. The original
trial stays pending; credentials remain in Keychain and no book data is written.
"""
import argparse
import hashlib
import json
import resource

from secure_native_session import NativeSessionStore
from secure_ordinary_partial_recovery import PartialRecoveryStore,RetryPartialRecoveryStore
from secure_ordinary_reconnect_trial import OrdinaryReconnectStore,OrdinaryReconnectRetryStore
from secure_ordinary_recovery_renewal import RecoveryRenewalStore,RetryRecoveryRenewalStore
from secure_weread_session import MacKeychain,SessionStore
from txt_full_summary import digest
from verify_eink_login import BASE,ProbeError
from verify_eink_renewal import RenewalProbe
from verify_native_txt_position import Native


def execute(original,original_receipt,session,native_store,bridge,saved,previous,current,report,*,reader_factory=Native,renewal_factory=RenewalProbe):
    if (any(isinstance(getattr(item,'backend',None),MacKeychain) for item in (original,session,native_store,bridge))
            and (reader_factory is not Native or renewal_factory is not RenewalProbe)):
        raise ValueError('ordinary_renewal/scope')
    state,receipt=original.read()
    allowed=('enter_pending','enter_acknowledged','enter_verified','position_pending','position_acknowledged','restore_pending','restore_acknowledged') if type(original) is OrdinaryReconnectRetryStore else ('enter_acknowledged',)
    if (not state or state['phase'] not in allowed or receipt!=original_receipt
            or digest(previous)!=state['plan']['grant_sha256'] or digest(saved)!=state['plan']['web_session_sha256']
            or digest(saved['vid'])!=state['plan']['owner_sha256'] or previous.get('vid')!=saved['vid']
            or bridge.read()[0] is not None or current() is not True):raise ValueError('ordinary_renewal/scope')
    reader=reader_factory(previous,state['plan']['baseline']['book_id'])
    for _ in range(2):
        try:reader.request('ordinary_renewal_expired',BASE+'/shelf/sync',credentials=previous)
        except ProbeError:pass
        else:raise ValueError('ordinary_renewal/not_expired')
        if not reader.report['stages'] or reader.report['stages'][-1].get('status')!=401:raise ValueError('ordinary_renewal/expiry')
    if current() is not True:raise ValueError('ordinary_renewal/currentness')
    bound=dict(original_intent_sha256=hashlib.sha256(original_receipt.pending).hexdigest(),owner_sha256=digest(saved['vid']),
               device_sha256=digest(previous['deviceId']),old_grant_sha256=digest(previous))
    intent=bridge.reserve(bound);state,receipt=original.read()
    if receipt!=original_receipt or current() is not True:raise ValueError('ordinary_renewal/currentness')
    intent=bridge.claim(intent);native_receipt=None;probe=renewal_factory();renewed=None
    try:
        native_receipt,actual=native_store.begin_renewal(saved['vid'],previous)
        if actual!=previous:raise ValueError('ordinary_renewal/currentness')
        report['authentication_posts_may_have_occurred']=True
        renewed,shelf=probe.renew(previous)
        report['authentication_posts_attempted']=probe.report.get('renewal_attempts',0)
        if renewed.get('vid')!=saved['vid'] or renewed.get('deviceId')!=previous['deviceId'] or not isinstance(shelf.get('books'),list):
            raise ValueError('ordinary_renewal/owner')
        native_store.finish_renewal(native_receipt,renewed,verified=True)
        if native_store.load(saved['vid'])!=renewed or original.read()[1]!=original_receipt or session.load()!=saved:
            raise ValueError('ordinary_renewal/currentness')
        bridge.finish(intent,digest(renewed))
        report.update(result='ORDINARY_RECOVERY_RENEWAL_VERIFIED',authentication_posts_may_have_occurred=False,
                      authentication_posts_attempted=1,same_owner_and_device=True,native_shelf_verified=True)
    finally:
        report['authentication_posts_attempted']=probe.report.get('renewal_attempts',0)
        if native_receipt is not None and report['authentication_posts_attempted']==0:
            try:native_store.release_renewal(native_receipt,not_dispatched=True)
            except Exception:pass
        if isinstance(renewed,dict):renewed.clear()


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--saved-session',action='store_true');p.add_argument('--renew',action='store_true');p.add_argument('--retry',action='store_true');a=p.parse_args(argv)
    if a.saved_session!=a.renew:p.error('pair saved session and renewal')
    if a.retry and not a.saved_session:p.error('retry scope requires saved session')
    report=dict(result='OFFLINE_ONLY',account_data_posts=0,authentication_posts_attempted=0,
                authentication_posts_may_have_occurred=False,private_data_on_regular_disk=False)
    saved=previous=None
    try:
        if a.saved_session:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0))
            from verify_native_thought_trial import other_pending
            original=(OrdinaryReconnectRetryStore if a.retry else OrdinaryReconnectStore)();state,receipt=original.read()
            recovery=(RetryPartialRecoveryStore if a.retry else PartialRecoveryStore)();bridge=(RetryRecoveryRenewalStore if a.retry else RecoveryRenewalStore)()
            allowed=('enter_pending','enter_acknowledged','enter_verified','position_pending','position_acknowledged','restore_pending','restore_acknowledged') if a.retry else ('enter_acknowledged',)
            if (not state or state['phase'] not in allowed or recovery.read()[0] is not None
                    or bridge.read()[0] is not None or other_pending(exclude_ordinary_reconnect_trial=not a.retry,exclude_ordinary_reconnect_retry=a.retry)):
                raise ValueError('ordinary_renewal/scope')
            session=SessionStore();saved=session.load();native_store=NativeSessionStore();previous=native_store.load(saved['vid'])
            def current():
                return (original.read()[1]==receipt and session.load()==saved and native_store.load(saved['vid'])==previous
                        and recovery.read()[0] is None and not other_pending(exclude_ordinary_reconnect_trial=not a.retry,exclude_ordinary_reconnect_retry=a.retry))
            execute(original,receipt,session,native_store,bridge,saved,previous,current,report)
    except Exception:
        report['result']='UNVERIFIED'
    finally:
        for value in (saved,previous):
            if isinstance(value,dict):value.clear()
    print(json.dumps(report,indent=2));return int(report['result']=='UNVERIFIED')

if __name__=='__main__':raise SystemExit(main())
