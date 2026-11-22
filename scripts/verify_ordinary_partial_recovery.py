#!/usr/bin/env python3
"""Prepare or perform one separately scoped partial-position restoration.

Default is offline. Preparation is read-only; apply sends at most one request.
The original trial remains unverified even if its position is restored.
"""
import argparse
from datetime import datetime,timezone
import json
import re
import resource
import traceback

from ordinary_partial_recovery import RecoveryProbe,binding,checked_pair,observed_point,restore_once,verified_grant
from secure_native_session import NativeSessionStore
from secure_ordinary_partial_recovery import PartialRecoveryStore,RetryPartialRecoveryStore,ThirdPartialRecoveryStore
from secure_ordinary_reconnect_trial import OrdinaryReconnectStore,OrdinaryReconnectRetryStore,OrdinaryReconnectThirdStore
from secure_ordinary_recovery_renewal import RecoveryRenewalStore,RetryRecoveryRenewalStore,ThirdRecoveryRenewalStore
from secure_weread_session import COOKIE_NAMES,SessionStore
from txt_full_summary import digest
from verify_native_txt_position import Native
from verify_ordinary_reconnect_preview import CapturedPreflight
from verify_position_roundtrip import same_position
from verify_reader_progress import find_node,project
from verify_translation_preflight import save_refreshed_web_session


class Reads(Native):max_reads=64


def choose_retry_state(plan,phase,raw):
    choices=('entered',) if phase in ('enter_pending','enter_acknowledged','enter_verified') else ('entered','target') \
        if phase in ('position_pending','position_acknowledged') else ()
    book=plan['baseline']['book_id'];point=project(raw,book);node=find_node(raw,book)
    for kind in choices:
        expected=observed_point(plan) if kind=='entered' else plan['target']
        if same_position(point,expected) and node.get('summary')==expected['summary']:return kind,expected
    raise ValueError('ordinary_recovery/observed')


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--saved-session',action='store_true')
    mode=p.add_mutually_exclusive_group();mode.add_argument('--prepare',action='store_true');mode.add_argument('--apply',action='store_true')
    scope=p.add_mutually_exclusive_group();scope.add_argument('--retry',action='store_true');scope.add_argument('--third',action='store_true')
    a=p.parse_args(argv)
    if (a.prepare or a.apply)!=a.saved_session:p.error('pair saved session with exactly one mode')
    scoped=a.retry or a.third
    if scoped and not a.saved_session:p.error('separate scope requires saved session')
    report=dict(result='OFFLINE_ONLY',checked_at=datetime.now(timezone.utc).isoformat(),account_data_posts=0,
                authentication_posts=0,private_data_on_regular_disk=False,original_trial_verified=False)
    saved=grant=web=native=None;private=set();restore_report={}
    try:
        if a.saved_session:
            resource.setrlimit(resource.RLIMIT_CORE,(0,0));report['phase']='intent'
            from verify_native_thought_trial import other_pending
            original=(OrdinaryReconnectThirdStore if a.third else OrdinaryReconnectRetryStore if a.retry else OrdinaryReconnectStore)();state,original_receipt=original.read()
            recovery=(ThirdPartialRecoveryStore if a.third else RetryPartialRecoveryStore if a.retry else PartialRecoveryStore)();rstate,rreceipt=recovery.read()
            allowed=('enter_pending','enter_acknowledged','enter_verified','position_pending','position_acknowledged') if scoped else ('enter_acknowledged',)
            if (not state or state['phase'] not in allowed or original_receipt is None
                    or a.prepare and rstate is not None or a.apply and (not rstate or rstate['phase']!='prepared')
                    or other_pending(exclude_ordinary_reconnect_trial=not scoped,exclude_ordinary_reconnect_retry=a.retry,exclude_ordinary_reconnect_third=a.third)):raise ValueError('ordinary_recovery/intent')
            plan=state['plan'];store=SessionStore();saved=store.load();grant=NativeSessionStore().load(saved['vid'])
            bridge=(ThirdRecoveryRenewalStore if a.third else RetryRecoveryRenewalStore if a.retry else RecoveryRenewalStore)();bridge_state,bridge_receipt=bridge.read()
            if digest(saved)!=plan['web_session_sha256']:raise ValueError('ordinary_recovery/session')
            grant_sha,bridge_sha=verified_grant(plan,original_receipt,saved,grant,bridge_state,bridge_receipt)
            private.update(str(v) for v in saved['cookies'].values());private.update(str(v) for v in grant.values() if isinstance(v,str))
            private.update((plan['baseline']['book_id'],plan['baseline']['summary'],plan['target']['summary']))
            web=CapturedPreflight();web.vid=saved['vid']
            for key,value in saved['cookies'].items():web.set_cookie(key,value)
            web.verify_account();native=Reads(grant,plan['baseline']['book_id'])
            def current():
                now,receipt=original.read()
                cookies={cookie.name:cookie.value for cookie in web.cookies if cookie.name in COOKIE_NAMES
                         and cookie.domain in ('.weread.qq.com','weread.qq.com') and cookie.path=='/'}
                return (now==state and receipt==original_receipt and store.load()==saved
                        and NativeSessionStore().load(saved['vid'])==grant and bridge.read()==(bridge_state,bridge_receipt) and cookies==saved['cookies']
                        and not other_pending(exclude_ordinary_reconnect_trial=not scoped,exclude_ordinary_reconnect_retry=a.retry,exclude_ordinary_reconnect_third=a.third))
            report['phase']='readback'
            if scoped:
                if current() is not True:raise ValueError('ordinary_recovery/currentness')
                web.inspect(plan['baseline']['book_id'])
                observed_state,expected=choose_retry_state(plan,state['phase'],web.raw_progress)
            else:observed_state,expected=None,observed_point(plan)
            sample=checked_pair(web,native,grant,plan,expected,current,grant_sha)
            bound=binding(original_receipt,sample,grant_sha,bridge_sha,observed_state=observed_state,
                          original_phase=state['phase'] if scoped else None)
            if a.prepare:
                if recovery.read()[0] is not None or current() is not True:raise ValueError('ordinary_recovery/intent')
                recovery.reserve(bound);ready,_=recovery.read()
                if not ready or ready['phase']!='prepared' or ready['binding']!=bound:raise ValueError('ordinary_recovery/intent')
                report.update(result='ORDINARY_PARTIAL_RECOVERY_PREPARED',independent_readbacks=2,
                              current_position_matches_observed=True,source_catalog_time_counts_unchanged=True)
            else:
                if rstate['binding']!=bound or current() is not True:raise ValueError('ordinary_recovery/changed')
                def factory(original_arg,original_receipt_arg,recovery_arg,recovery_receipt_arg,plan_arg,wire_arg,current_arg):
                    probe=RecoveryProbe(original_arg,original_receipt_arg,recovery_arg,recovery_receipt_arg,plan_arg,wire_arg,current_arg)
                    probe.vid=saved['vid'];probe.book_id=plan['baseline']['book_id']
                    for key,value in saved['cookies'].items():probe.set_cookie(key,value)
                    probe.verify_account();return probe
                report['phase']='restore';report['account_data_posts']=None
                restore_once(original,original_receipt,recovery,rreceipt,web,native,grant,plan,bound,current,factory,restore_report)
                if restore_report.get('result')!='ORDINARY_PARTIAL_RECOVERY_VERIFIED':raise ValueError('ordinary_recovery/restore')
                report.update(result='ORDINARY_PARTIAL_RECOVERY_VERIFIED',account_data_posts=1,independent_readbacks=2,
                              original_position_and_summary_restored=True,time_counts_unchanged=True,
                              source_catalog_unchanged=True,shelf_core_unchanged=True)
            report['phase']='complete'
    except Exception as error:
        report['result']='UNVERIFIED'
        if isinstance(error,ValueError) and re.fullmatch(r'ordinary_recovery/[a-z_]+',str(error)):report['reason']=str(error)
        else:
            frames=traceback.extract_tb(error.__traceback__)
            report['diagnostic']={'type':type(error).__name__,
                                  'frames':[{'function':item.name,'line':item.lineno} for item in frames[-3:]]}
    finally:
        if restore_report:
            report['restore']={key:restore_report[key] for key in ('result','restore_claimed','restore_claim_interrupted','restore_acknowledged',
                'original_position_restored','web_shelf_stable_fields_unchanged','native_shelf_stable_fields_unchanged') if key in restore_report}
            if report['result']!='ORDINARY_PARTIAL_RECOVERY_VERIFIED':
                if restore_report.get('restore_acknowledged'):report['account_data_posts']=1
                elif not (restore_report.get('restore_claimed') or restore_report.get('restore_claim_interrupted')):report['account_data_posts']=0
        if web:
            if web.authenticated:
                try:web.verify_account();save_refreshed_web_session(store,store.load(),web)
                except Exception:report['result']='UNVERIFIED';report['reason']='ordinary_recovery/session'
            report['web_stages']=[{k:row[k] for k in ('stage','status','api_code') if k in row} for row in web.report['stages']]
            web.shards.clear();web.close()
        if native:
            report['native_stages']=[{k:row[k] for k in ('stage','status','error_code') if k in row} for row in native.report['stages']]
        for value in (saved,grant):
            if isinstance(value,dict):value.clear()
    encoded=json.dumps(report,ensure_ascii=True)
    if any(len(value)>=8 and (value in encoded or json.dumps(value,ensure_ascii=True)[1:-1] in encoded) for value in private):
        report=dict(result='UNVERIFIED',reason='ordinary_recovery/privacy',account_data_posts=None if a.apply else 0,authentication_posts=0)
    print(json.dumps(report,ensure_ascii=False,indent=2));return int(report['result']=='UNVERIFIED')

if __name__=='__main__':raise SystemExit(main())
