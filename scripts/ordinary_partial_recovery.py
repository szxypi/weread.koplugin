"""Independent inspection and one-shot restoration after a partial enter.

The first trial remains unverified. A distinct Keychain intent permits at most
one explicit restore, only after both services agree on the observed state.
"""
from copy import deepcopy
import hashlib

from fetch_weread_epub import decode_content_shards,weread_e
from ordinary_reconnect_restore import RestoreProbe
from readtime_upload_model import integer
from secure_ordinary_partial_recovery import PartialRecoveryStore,RetryPartialRecoveryStore,validate_binding,validate_retry_binding
from secure_ordinary_reconnect_trial import OrdinaryReconnectStore,OrdinaryReconnectRetryStore,entered_point,validate_plan
from secure_weread_session import COOKIE_NAMES
from shelf_flag_change_contract import state_hash
from txt_full_summary import digest
from verify_eink_login import BASE as NATIVE
from verify_ordinary_reconnect_rpc_preview import native_snapshot,same_shelf,stable_shelf
from verify_position_roundtrip import WRITE_URL,acknowledged,canonical,payload,validate_payload,same_position
from verify_reader_progress import find_node,project
from verify_web_source_progress import BASE as WEB


def observed_point(plan):
    return entered_point(plan)


def verified_grant(plan,original_receipt,saved,grant,bridge_state,bridge_receipt):
    validate_plan(plan)
    if (not isinstance(saved,dict) or not isinstance(grant,dict) or digest(saved.get('vid'))!=plan['owner_sha256']
            or grant.get('vid')!=saved.get('vid') or not hasattr(original_receipt,'pending')):
        raise ValueError('ordinary_recovery/session')
    grant_sha=digest(grant)
    if bridge_state is None:
        if bridge_receipt is not None or grant_sha!=plan['grant_sha256']:raise ValueError('ordinary_recovery/session')
        return grant_sha,'0'*64
    if (not isinstance(bridge_state,dict) or bridge_state.get('phase')!='verified' or not hasattr(bridge_receipt,'pending')
            or bridge_state.get('new_grant_sha256')!=grant_sha or not isinstance(bridge_state.get('binding'),dict)):
        raise ValueError('ordinary_recovery/session')
    expected=dict(original_intent_sha256=hashlib.sha256(original_receipt.pending).hexdigest(),
                  owner_sha256=plan['owner_sha256'],device_sha256=digest(grant.get('deviceId')),
                  old_grant_sha256=plan['grant_sha256'])
    if bridge_state['binding']!=expected:raise ValueError('ordinary_recovery/session')
    return grant_sha,hashlib.sha256(bridge_receipt.pending).hexdigest()


def snapshot(web,native,grant,plan,expected,current,grant_sha256=None):
    validate_plan(plan)
    if not callable(current) or current() is not True or digest(web.vid)!=plan['owner_sha256'] or digest(grant)!=(grant_sha256 or plan['grant_sha256']):
        raise ValueError('ordinary_recovery/currentness')
    identity=plan['baseline']['book_id'];web.verify_account();web.inspect(identity)
    node=find_node(web.raw_progress,identity)
    if (not web.report.get('read_snapshot_consistent') or not same_position(project(web.raw_progress,identity),expected)
            or node.get('summary')!=expected['summary'] or digest(web.catalog)!=plan['catalog_sha256']):
        raise ValueError('ordinary_recovery/web_state')
    source=decode_content_shards(*(web.shards[k] for k in ('e_0','e_1','e_3')))
    if hashlib.sha256(source.encode()).hexdigest()!=plan['source_sha256']:raise ValueError('ordinary_recovery/source')
    actual=native_snapshot(native,grant,identity,expected)
    if actual['counts']!=plan['counts']:raise ValueError('ordinary_recovery/counts')
    info=native.request('ordinary_rpc_info',NATIVE+'/book/info?bookId='+identity,credentials=grant)
    versions=[info[k] for k in ('bookVersion','version') if k in info]
    if (str(info.get('bookId'))!=identity or not versions
            or any(not integer(v,0,2147483647) or v!=plan['version'] for v in versions)):
        raise ValueError('ordinary_recovery/version')
    web_shelf=web.request('shelf',WEB+'/web/shelf/sync')
    native_shelf=native.request('ordinary_rpc_shelf',NATIVE+'/shelf/sync',credentials=grant)
    if current() is not True:raise ValueError('ordinary_recovery/currentness')
    return dict(web_shelf=deepcopy(web_shelf),native_shelf=deepcopy(native_shelf),context=deepcopy(web.reader))


def checked_pair(web,native,grant,plan,expected,current,grant_sha256=None):
    first=snapshot(web,native,grant,plan,expected,current,grant_sha256)
    later=snapshot(web,native,grant,plan,expected,current,grant_sha256)
    if (not same_shelf(first['web_shelf'],later['web_shelf']) or not same_shelf(first['native_shelf'],later['native_shelf'])
            or state_hash(first['web_shelf'])!=state_hash(later['web_shelf'])
            or state_hash(first['native_shelf'])!=state_hash(later['native_shelf'])):
        raise ValueError('ordinary_recovery/shelf')
    return later


def binding(original_receipt,observed,grant_sha256,renewal_bridge_sha256,*,observed_state=None,original_phase=None):
    value=dict(original_intent_sha256=hashlib.sha256(original_receipt.pending).hexdigest(),
        web_shelf_sha256=digest(stable_shelf(observed['web_shelf'])),native_shelf_sha256=digest(stable_shelf(observed['native_shelf'])),
        web_shelf_core_sha256=state_hash(observed['web_shelf']),native_shelf_core_sha256=state_hash(observed['native_shelf']),
        native_grant_sha256=grant_sha256,renewal_bridge_sha256=renewal_bridge_sha256)
    if observed_state is None and original_phase is None:return validate_binding(value)
    value.update(observed_state=observed_state,original_phase=original_phase)
    return validate_retry_binding(value)


def recovery_scope(original,original_state,recovery,bound,plan):
    phase=original_state.get('phase') if isinstance(original_state,dict) else None
    if type(original) is OrdinaryReconnectStore and type(recovery) is PartialRecoveryStore:
        if phase!='enter_acknowledged' or 'observed_state' in bound:raise ValueError('ordinary_recovery/intent')
        return observed_point(plan)
    if type(original) is not OrdinaryReconnectRetryStore or type(recovery) is not RetryPartialRecoveryStore:
        raise ValueError('ordinary_recovery/intent')
    if bound.get('original_phase')!=phase:raise ValueError('ordinary_recovery/intent')
    observed=bound.get('observed_state')
    if phase in ('enter_pending','enter_acknowledged','enter_verified') and observed=='entered':return observed_point(plan)
    if phase in ('position_pending','position_acknowledged') and observed in ('entered','target'):
        return observed_point(plan) if observed=='entered' else plan['target']
    raise ValueError('ordinary_recovery/intent')


class RecoveryProbe(RestoreProbe):
    def __init__(self,original,original_receipt,recovery,recovery_receipt,plan,wire,current,*args,**kwargs):
        super().__init__(*args,**kwargs)
        self.original,self.original_receipt,self.recovery,self.recovery_receipt=original,original_receipt,recovery,recovery_receipt
        self.plan,self.wire,self.current=plan,wire,current
    def guard(self,stage,url,body):
        if stage!='write_restore':return super().guard(stage,url,body)
        original,original_receipt=self.original.read();recovery,recovery_receipt=self.recovery.read()
        if (not original or original['plan']!=self.plan or original_receipt!=self.original_receipt
                or not recovery or recovery['phase']!='pending' or recovery_receipt!=self.recovery_receipt
                or recovery['binding']['original_intent_sha256']!=hashlib.sha256(original_receipt.pending).hexdigest()
                or self.current() is not True or digest(self.vid)!=self.plan['owner_sha256']
                or self.book_id!=self.plan['baseline']['book_id']):raise ValueError('ordinary_recovery/scope')
        recovery_scope(self.original,original,self.recovery,recovery['binding'],self.plan)
        validate_payload(self.wire,'write_restore',body)
        return super().guard(stage,url,body)


def restore_once(original,original_receipt,recovery,recovery_receipt,web,native,grant,plan,bound,current,probe_factory,report):
    if (not isinstance(original,OrdinaryReconnectStore) or not isinstance(recovery,PartialRecoveryStore)
            or not callable(current) or not callable(probe_factory)):
        raise ValueError('ordinary_recovery/scope')
    state,receipt=original.read();pending,pending_receipt=recovery.read()
    if (not state or receipt!=original_receipt or state['plan']!=plan
            or not pending or pending['phase']!='prepared' or pending_receipt!=recovery_receipt or pending['binding']!=bound
            or current() is not True):raise ValueError('ordinary_recovery/intent')
    expected=recovery_scope(original,state,recovery,bound,plan)
    report.update(result='UNVERIFIED',restore_claimed=False,restore_claim_interrupted=False,restore_acknowledged=False,
                  original_position_restored=False)
    sample=checked_pair(web,native,grant,plan,expected,current,bound['native_grant_sha256'])
    if binding(original_receipt,sample,bound['native_grant_sha256'],bound['renewal_bridge_sha256'],
               observed_state=bound.get('observed_state'),original_phase=bound.get('original_phase'))!=bound:raise ValueError('ordinary_recovery/changed')
    context=sample['context'];fixed=context.get('pclts')
    if fixed is None or type(fixed) is str and fixed in ('','0') or type(fixed) is int and fixed==0:
        import time
        fixed=weread_e(int(time.time()))
    wire=dict(book_id=plan['baseline']['book_id'],baseline=plan['baseline'],target=None,context=context,pclts=fixed)
    body=payload(wire,'write_restore');validate_payload(wire,'write_restore',body)
    probe=probe_factory(original,original_receipt,recovery,recovery_receipt,plan,wire,current)
    if not isinstance(probe,RecoveryProbe):raise ValueError('ordinary_recovery/scope')
    try:
        def cookies(client):
            return {cookie.name:cookie.value for cookie in client.cookies if cookie.name in COOKIE_NAMES
                    and cookie.domain in ('.weread.qq.com','weread.qq.com') and cookie.path=='/'}
        if (not probe.authenticated or probe.book_id!=plan['baseline']['book_id'] or digest(probe.vid)!=plan['owner_sha256']
                or cookies(probe)!=cookies(web) or current() is not True):
            raise ValueError('ordinary_recovery/scope')
        probe.current=lambda: current() is True and cookies(probe)==cookies(web)
        validate_payload(wire,'write_restore',body)
        report['restore_claim_interrupted']=True
        pending_receipt=recovery.advance(recovery_receipt,'prepared','pending')
        report.update(restore_claim_interrupted=False,restore_claimed=True)
        probe.recovery_receipt=pending_receipt
        probe._pending_body=canonical(body)
        try:response=probe.request('write_restore',WRITE_URL,body)
        finally:probe._pending_body=None
        rows=probe.report['stages']
        if (not probe._used or not rows or rows[-1].get('status')!=200 or acknowledged(response) is not True):
            raise ValueError('ordinary_recovery/ack')
        pending_receipt=recovery.advance(pending_receipt,'pending','acknowledged');report['restore_acknowledged']=True
    finally:probe.close()
    after=checked_pair(web,native,grant,plan,plan['baseline'],current,bound['native_grant_sha256'])
    if (state_hash(after['web_shelf'])!=bound['web_shelf_core_sha256']
            or state_hash(after['native_shelf'])!=bound['native_shelf_core_sha256']):raise ValueError('ordinary_recovery/shelf')
    report['web_shelf_stable_fields_unchanged']=digest(stable_shelf(after['web_shelf']))==bound['web_shelf_sha256']
    report['native_shelf_stable_fields_unchanged']=digest(stable_shelf(after['native_shelf']))==bound['native_shelf_sha256']
    pending_receipt=recovery.advance(pending_receipt,'acknowledged','retired')
    original.retire_after_partial_recovery(original_receipt,recovery)
    report.update(result='ORDINARY_PARTIAL_RECOVERY_VERIFIED',original_position_restored=True)
