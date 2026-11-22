import copy
import hashlib
import unittest
from unittest.mock import patch

import ordinary_reconnect_live as subject
from ordinary_reconnect_restore import RestoreProbe
from secure_ordinary_reconnect_trial import OrdinaryReconnectStore
from test_ordinary_reconnect_body_guard import body
from test_secure_native_session import Backend
from test_secure_ordinary_reconnect_trial import plan
from txt_full_summary import digest


class LiveCoordinatorTests(unittest.TestCase):
    def setUp(self):
        self.plan=plan();self.source='<html>synthetic source</html>';self.grant={}
        self.plan['source_sha256']=hashlib.sha256(self.source.encode()).hexdigest()
        self.plan['owner_sha256']=digest('900000');self.plan['grant_sha256']=digest(self.grant)
        self.payload=dict(ordinary=True,reconnect=True,source_format='web_xhtml',book='900001',chapter='123',chapter_idx=3,
            first_offset=100,next_offset=300,expected_summary=self.plan['target']['summary'],source=self.source,
            book_version=0,owner='900000',cookies={'wr_vid':'900000','wr_skey':'synthetic'})
        self.context={'psvts':'synthetic-ps','token':'synthetic-token','pclts':'synthetic-pc'};self.pc='synthetic-pc'
        self.store=OrdinaryReconnectStore(Backend());self.store.reserve(self.plan)
        self.probe=RestoreProbe();self.addCleanup(self.probe.close);self.probe.vid='900000';self.probe.book_id='900001';self.probe.authenticated=True
        self.web=RestoreProbe();self.addCleanup(self.web.close);self.web.vid='900000';self.web.book_id='900001';self.web.authenticated=True
        for key,value in self.payload['cookies'].items():self.web.set_cookie(key,value);self.probe.set_cookie(key,value)
        self.events=[];self.report={}
    def run_case(self,*,noack=False,observer=None):
        def bind(_html,_plan):return dict(context=self.context,pclts=self.pc)
        def check(*args):
            self.events.append(('check',args[4]['chapter_offset']))
            return observer(*args) if observer else True
        def preview(_cmd,payload,check_body,report,*,check_context):
            self.assertIs(payload['armed'],False);self.assertTrue(check_context('synthetic context'))
            self.assertTrue(check_body(body(self.plan,self.context,self.pc,'enter')))
            report['result']='READER_POSITION_DRY_VERIFIED'
        def reader(_cmd,payload,gate,report,*,check_context):
            self.assertIs(payload['armed'],True);binding=check_context('synthetic context');gate.bind_context(binding['context'],binding['pclts'])
            for seq,stage in enumerate(('enter','position'),1):
                gate.claim(stage,body(self.plan,self.context,self.pc,stage));report['claimed_posts']=seq
                if noack:
                    gate.phase='stopped';raise ValueError('synthetic noack')
                gate.ack(stage,200,{'succ':1});gate.verify(stage)
                report.update(acknowledged_posts=seq,independently_verified=seq)
            report['result']='READER_POSITION_VERIFIED_RESTORE_PENDING'
        def restore(_probe,gate,_current,report):
            gate.claim('restore',body(self.plan,self.context,self.pc,'restore'));report['restore_claimed']=True
            gate.ack('restore',200,{'succ':1});report['restore_acknowledged']=True;gate.verify('restore')
            report['result']='ORDINARY_RESTORATION_VERIFIED'
        with patch.object(subject,'context_binding',side_effect=bind),patch.object(subject,'observe',side_effect=check), \
             patch.object(subject,'preview',side_effect=preview),patch.object(subject,'reader_execute',side_effect=reader), \
             patch.object(subject,'restore',side_effect=restore):
            subject.execute(self.store,self.plan,self.payload,['synthetic-runner'],self.web,object(),self.grant,self.probe,lambda:True,self.report)

    def test_completed_stages_return_to_original_and_retire_once(self):
        self.run_case()
        self.assertEqual(self.report['result'],'ORDINARY_RECONNECT_TRIAL_VERIFIED')
        self.assertTrue(self.report['dry_verified']);self.assertTrue(self.report['restoration_verified'])
        self.assertEqual(self.store.read()[0]['phase'],'retired')
        self.assertEqual(self.report['claimed_posts'],2);self.assertTrue(self.report['restore_claimed'])
        with self.assertRaises(ValueError):self.run_case()

    def test_unconfirmed_send_stops_and_retains_claim(self):
        with self.assertRaisesRegex(ValueError,'noack'):self.run_case(noack=True)
        self.assertEqual(self.store.read()[0]['phase'],'enter_pending')
        self.assertEqual(self.report['result'],'UNVERIFIED');self.assertFalse(self.report['restoration_verified'])
        self.assertEqual(self.report['claimed_posts'],1);self.assertFalse(self.report['restore_claimed'])
        with self.assertRaises(ValueError):self.run_case()

    def test_preflight_failure_never_claims(self):
        with self.assertRaisesRegex(ValueError,'readback'):self.run_case(observer=lambda *_:False)
        self.assertEqual(self.store.read()[0]['phase'],'prepared')
        self.assertEqual(self.report['claimed_posts'],0)

    def test_foreign_source_target_or_owner_is_rejected(self):
        for key,value in [('book','900002'),('next_offset',999),('expected_summary','changed'),('source','changed'),('owner','other')]:
            with self.subTest(key=key):
                bad=copy.deepcopy(self.payload);bad[key]=value
                with self.assertRaises(ValueError):subject.validate_input(self.plan,bad)
        self.assertEqual(self.store.read()[0]['phase'],'prepared')


if __name__=='__main__':unittest.main()
