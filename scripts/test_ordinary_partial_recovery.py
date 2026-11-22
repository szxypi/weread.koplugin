import copy
import hashlib
import json
import unittest
from urllib.error import URLError
from unittest.mock import patch

import ordinary_partial_recovery as task
from secure_ordinary_partial_recovery import PartialRecoveryStore
from secure_ordinary_reconnect_trial import OrdinaryReconnectStore
from secure_ordinary_reconnect_trial import OrdinaryReconnectRetryStore,OrdinaryReconnectThirdStore
from secure_ordinary_partial_recovery import ThirdPartialRecoveryStore
from secure_ordinary_partial_recovery import RetryPartialRecoveryStore
from test_ordinary_reconnect_observe import Web,Native
from test_ordinary_reconnect_restore import Response
from test_secure_native_session import Backend
from test_secure_ordinary_reconnect_trial import plan
from secure_ordinary_recovery_renewal import RecoveryRenewalStore
from txt_full_summary import digest


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.plan=plan();self.grant={'synthetic':'grant'};self.shelf={'books':[{'bookId':'900001'}],'lectureSynckey':123}
        self.plan.update(owner_sha256=digest('900000'),grant_sha256=digest(self.grant),
            source_sha256=hashlib.sha256(b'synthetic source').hexdigest(),catalog_sha256=digest({'catalog':'synthetic'}))
        observed=task.observed_point(self.plan)
        self.web=Web(observed,copy.deepcopy(self.shelf));self.native=Native(observed,self.plan['counts'],copy.deepcopy(self.shelf))
        self.web.reader={'psvts':'synthetic-ps','token':'synthetic-token','pclts':0}
        self.cookie_holder=task.RestoreProbe();self.cookie_holder.set_cookie('wr_vid','900000');self.cookie_holder.set_cookie('wr_skey','synthetic-cookie-session')
        self.web.cookies=self.cookie_holder.cookies;self.addCleanup(self.cookie_holder.close)
        self.original=OrdinaryReconnectStore(Backend());self.original_receipt=self.original.reserve(self.plan)
        self.original_receipt=self.original.advance(self.original_receipt,'prepared','enter_pending')
        self.original_receipt=self.original.advance(self.original_receipt,'enter_pending','enter_acknowledged')
        self.recovery=PartialRecoveryStore(Backend());self.posts=0;self.mode='success';self.report={}
        self.decoder=patch.object(task,'decode_content_shards',return_value='synthetic source');self.decoder.start();self.addCleanup(self.decoder.stop)
        sample=task.checked_pair(self.web,self.native,self.grant,self.plan,observed,lambda:True)
        self.bound=task.binding(self.original_receipt,sample,digest(self.grant),'0'*64);self.recovery_receipt=self.recovery.reserve(self.bound)
    def factory(self,*args):
        owner=self
        class Opener:
            def open(self,request,timeout):
                owner.posts+=1
                if owner.mode=='network':raise URLError('synthetic')
                value=json.loads(request.data)
                assert value['co']==owner.plan['baseline']['chapter_offset'] and value['sm']==owner.plan['baseline']['summary'] and value['rt']==0
                owner.web.point=copy.deepcopy(owner.plan['baseline']);owner.native.point=copy.deepcopy(owner.plan['baseline'])
                if owner.mode=='shelf':owner.web.shelf['recent']=1;owner.native.shelf['recent']=1
                return Response({} if owner.mode=='noack' else {'succ':1})
        probe=task.RecoveryProbe(*args,opener=Opener());probe.vid='900000';probe.book_id='900001';probe.authenticated=True
        probe.set_cookie('wr_vid','900000');probe.set_cookie('wr_skey','synthetic-cookie-session')
        return probe
    def run_recovery(self):
        task.restore_once(self.original,self.original_receipt,self.recovery,self.recovery_receipt,self.web,self.native,
                          self.grant,self.plan,self.bound,lambda:True,self.factory,self.report)
    def test_single_restore_verifies_then_seals_both_records(self):
        self.run_recovery()
        self.assertEqual(self.posts,1);self.assertEqual(self.report['result'],'ORDINARY_PARTIAL_RECOVERY_VERIFIED')
        self.assertEqual(self.original.read()[0]['phase'],'partial_restored');self.assertEqual(self.recovery.read()[0]['phase'],'retired')
        self.assertFalse(self.original.pending());self.assertFalse(self.recovery.pending())
        with self.assertRaises(ValueError):self.run_recovery()
        self.assertEqual(self.posts,1)
    def test_missing_ack_or_disconnect_never_resends(self):
        for mode in ('noack','network'):
            with self.subTest(mode=mode):
                self.setUp();self.mode=mode
                with self.assertRaises(Exception):self.run_recovery()
                self.assertEqual(self.posts,1);self.assertEqual(self.original.read()[0]['phase'],'enter_acknowledged')
                self.assertEqual(self.recovery.read()[0]['phase'],'pending');self.assertFalse(self.report['original_position_restored'])
                with self.assertRaises(ValueError):self.run_recovery()
                self.assertEqual(self.posts,1)
    def test_original_change_blocks_before_claim(self):
        self.web.point['chapter_offset']+=1
        with self.assertRaises(ValueError):self.run_recovery()
        self.assertEqual(self.posts,0);self.assertEqual(self.recovery.read()[0]['phase'],'prepared')
    def test_noncore_shelf_changes_are_reported_after_restoration(self):
        self.mode='shelf';self.run_recovery()
        self.assertTrue(self.report['original_position_restored'])
        self.assertFalse(self.report['web_shelf_stable_fields_unchanged']);self.assertFalse(self.report['native_shelf_stable_fields_unchanged'])

    def test_new_native_grant_requires_verified_same_owner_device_bridge(self):
        old={'vid':'900000','deviceId':'synthetic-device','accessToken':'old'}
        new=dict(old,accessToken='new');selected=copy.deepcopy(self.plan);selected['grant_sha256']=digest(old)
        saved={'vid':'900000'}
        self.assertEqual(task.verified_grant(selected,self.original_receipt,saved,old,None,None),(digest(old),'0'*64))
        with self.assertRaises(ValueError):task.verified_grant(selected,self.original_receipt,saved,new,None,None)
        bridge=RecoveryRenewalStore(Backend())
        value=dict(original_intent_sha256=hashlib.sha256(self.original_receipt.pending).hexdigest(),owner_sha256=selected['owner_sha256'],
                   device_sha256=digest(old['deviceId']),old_grant_sha256=digest(old))
        receipt=bridge.reserve(value);receipt=bridge.claim(receipt)
        with self.assertRaises(ValueError):task.verified_grant(selected,self.original_receipt,saved,new,*bridge.read())
        bridge.finish(receipt,digest(new));state,receipt=bridge.read()
        self.assertEqual(task.verified_grant(selected,self.original_receipt,saved,new,state,receipt)[0],digest(new))
        for foreign in (dict(new,vid='900099'),dict(new,deviceId='other')):
            with self.assertRaises(ValueError):task.verified_grant(selected,self.original_receipt,saved,foreign,state,receipt)

    def test_retry_recovery_only_accepts_known_states_at_the_matching_phase(self):
        original=OrdinaryReconnectRetryStore(Backend());recovery=RetryPartialRecoveryStore(Backend())
        selected=dict(plan(),web_shelf_core_sha256='a'*64,native_shelf_core_sha256='b'*64);receipt=original.reserve(selected)
        receipt=original.advance(receipt,'prepared','enter_pending')
        bound=dict(self.bound,observed_state='entered',original_phase='enter_pending')
        self.assertEqual(task.recovery_scope(original,original.read()[0],recovery,bound,selected),task.observed_point(selected))
        with self.assertRaises(ValueError):task.recovery_scope(original,original.read()[0],recovery,dict(bound,observed_state='target'),selected)
        for before,after in (('enter_pending','enter_acknowledged'),('enter_acknowledged','enter_verified'),('enter_verified','position_pending')):
            receipt=original.advance(receipt,before,after)
        bound['original_phase']='position_pending'
        self.assertEqual(task.recovery_scope(original,original.read()[0],recovery,dict(bound,observed_state='target'),selected),selected['target'])
        with self.assertRaises(ValueError):task.recovery_scope(original,original.read()[0],self.recovery,bound,selected)

    def test_third_recovery_cannot_use_second_scope_record(self):
        original=OrdinaryReconnectThirdStore(Backend());recovery=ThirdPartialRecoveryStore(Backend())
        selected=dict(plan(),web_shelf_core_sha256='a'*64,native_shelf_core_sha256='b'*64)
        receipt=original.reserve(selected);original.advance(receipt,'prepared','enter_pending')
        bound=dict(self.bound,observed_state='entered',original_phase='enter_pending')
        self.assertEqual(task.recovery_scope(original,original.read()[0],recovery,bound,selected),task.observed_point(selected))
        with self.assertRaises(ValueError):task.recovery_scope(original,original.read()[0],RetryPartialRecoveryStore(Backend()),bound,selected)


if __name__=='__main__':unittest.main()
