#!/usr/bin/env python3
"""Offline supervision tests: malformed plans, unknown receipts and no replay."""
from copy import deepcopy
from contextlib import ExitStack
import time
import unittest
from unittest.mock import patch

from native_direct_ui_trial_broker import PROTOCOL,bind_metadata,execute
from native_txt_read_model import body
from readtime_upload_model import guest_token
from secure_native_direct_ui_trial import NativeDirectUITrialStore
from test_secure_native_session import Backend
from txt_full_summary import digest
from verify_source_coordinates import FilteredSource


class BrokerTests(unittest.TestCase):
    def setUp(self):
        self.raw=b'<html><body><p>Unique source beginning contains many different words for a safe synthetic target and readback.</p></body></html>'
        model=FilteredSource(self.raw.decode());visible=[i for i,c in enumerate(model.characters) if not c.isspace()]
        text=''.join(model.characters[i] for i in visible);index=4;offset=model.starts[visible[index]]
        self.before=dict(book_id='41',chapter_uid='2',chapter_idx=3,chapter_offset=999,raw_percent=17,summary='old cloud summary')
        self.target=dict(self.before,chapter_offset=offset,summary=text[index:index+20])
        self.creds=dict(vid='900000',deviceId='eink334691225'+'1'*19,accessToken='synthetic-access',refreshToken='synthetic-refresh')
        self.plan=dict(protocol=PROTOCOL,owner_sha256=digest(self.creds['vid']),source_sha256='a'*64,catalog_sha256='b'*64,
            grant_sha256=digest(self.creds),shelf_sha256='c'*64,baseline=self.before,target=self.before,
            counts=dict(readingTime=10,recordReadingTime=20,ttsTime=0),version=0,chapter_progress=None)
        self.metadata=dict(book_id='41',before=self.before,desired=self.target,counts=self.plan['counts'],version=0,
            shelf_sha256=self.plan['shelf_sha256'],source_sha256=self.plan['source_sha256'],file_id='d'*64,basis='filtered_xhtml_utf16')
        self.anchor=dict(text=text,point_offset=index)
        self.guest=guest_token({'feature':{}})[0];self.zone='+08:00'
        self.store=NativeDirectUITrialStore(Backend());self.report={};self.events=[]

    def frame(self,kind,seq,**values):return ('STEP',dict(kind=kind,seq=seq,**values))
    def request(self,point):return body(self.creds,point,0,self.guest,int(time.time()),123,self.zone)
    def payload(self,armed):return dict(credentials=self.creds,trial=dict(armed=armed,plan=self.plan,guest=self.guest,
        time_zone=self.zone,rpc_token='a'*32),mock_endpoint='http://127.0.0.1:1')
    def run_sequence(self,frames,armed=True,after=None):
        owner=self
        class Child:
            stdin=object();stdout=object()
            def wait(self,timeout=None):return 0
            def poll(self):return None
        class FrameSource:
            def __init__(self,*_args,**_kwargs):self.frames=iter(frames)
            def next(self):return next(self.frames)
        def before(seq,_plan):owner.events.append(('before',seq))
        def checked(seq,_plan):
            owner.events.append(('after',seq))
            if after:after(seq)
        with patch('native_direct_ui_trial_broker.subprocess.Popen',return_value=Child()), \
             patch('native_direct_ui_trial_broker.Frames',FrameSource), \
             patch('native_direct_ui_trial_broker.write_initial'),patch('native_direct_ui_trial_broker.reply'), \
             patch('native_direct_ui_trial_broker.stop'):
            return execute(self.payload(armed),['synthetic'],self.store,self.raw,self.report,
                current=lambda:None,before=before,after=checked)
    def plan_frame(self):return self.frame('plan',1,metadata=deepcopy(self.metadata),anchor=deepcopy(self.anchor))
    def result(self,armed):return ('RESULT',dict(result='PASS',profile_removed=True,credential_file_audit=True,
        installed_bytes_match=True,steps=2 if armed else 0,posts=2 if armed else 0,blocked=not armed))

    def test_two_posts_are_claimed_once_and_verified_before_restore(self):
        frames=[self.plan_frame(),self.frame('claim',1,body=self.request(self.target)),self.frame('ack',1),self.frame('verified',1),
            self.frame('claim',2,body=self.request(self.before)),self.frame('ack',2),self.frame('verified',2),self.result(True)]
        self.run_sequence(frames)
        self.assertEqual(self.store.read()[0]['phase'],'retired')
        self.assertEqual(self.events,[('before',1),('before',1),('after',1),('before',2),('after',2)])
        self.assertEqual(self.report['synthetic_posts'],2)

    def test_dry_run_does_not_create_intent(self):
        self.run_sequence([self.plan_frame(),self.frame('dry_body',1,body=self.request(self.target)),self.result(False)],False)
        self.assertIsNone(self.store.read()[0]);self.assertEqual(self.report['account_data_posts'],0)

    def test_changed_source_or_summary_is_rejected_before_claim(self):
        for mutate in (lambda m:m['desired'].__setitem__('summary','wrong'),
                       lambda m:m.__setitem__('source_sha256','f'*64)):
            metadata=deepcopy(self.metadata);mutate(metadata)
            with self.assertRaises(ValueError):bind_metadata(metadata,self.anchor,self.plan,self.raw)

    def test_invalid_body_is_never_claimed(self):
        bad=self.request(self.target);bad['readingTime']=1
        with self.assertRaises(ValueError):self.run_sequence([self.plan_frame(),self.frame('claim',1,body=bad)])
        self.assertEqual(self.store.read()[0]['phase'],'prepared');self.assertEqual(self.report['synthetic_posts'],0)

    def test_lost_ack_stays_pending_and_is_not_replayed(self):
        frames=[self.plan_frame(),self.frame('claim',1,body=self.request(self.target)),self.result(True)]
        with self.assertRaises(ValueError):self.run_sequence(frames)
        self.assertEqual(self.store.read()[0]['phase'],'advance_pending');self.assertEqual(self.report['synthetic_posts'],1)
        with self.assertRaises(ValueError):self.run_sequence(frames)

    def test_duplicate_claim_is_rejected_before_a_second_post(self):
        claim=self.frame('claim',1,body=self.request(self.target))
        with self.assertRaises(ValueError):self.run_sequence([self.plan_frame(),claim,claim])
        self.assertEqual(self.store.read()[0]['phase'],'advance_pending');self.assertEqual(self.report['synthetic_posts'],1)

    def test_independent_readback_failure_prevents_restore(self):
        frames=[self.plan_frame(),self.frame('claim',1,body=self.request(self.target)),self.frame('ack',1),self.frame('verified',1)]
        with self.assertRaises(ValueError):self.run_sequence(frames,after=lambda _seq:(_ for _ in ()).throw(ValueError('changed')))
        self.assertEqual(self.store.read()[0]['phase'],'advance_acknowledged');self.assertEqual(self.report['synthetic_posts'],1)

    def test_pending_direct_trials_block_other_account_writes(self):
        import verify_native_thought_trial as shared
        with ExitStack() as stack:
            factories={}
            for name in dir(shared):
                if name.endswith('Store'):
                    factory=stack.enter_context(patch.object(shared,name))
                    factory.return_value.pending.return_value=False;factory.return_value.read.return_value=(None,None)
                    factories[name]=factory
            self.assertFalse(shared.other_pending())
            for name in ('DirectTrialStore','NativeDirectUITrialStore'):
                factories[name].return_value.pending.return_value=True
                self.assertTrue(shared.other_pending())
                factories[name].return_value.pending.return_value=False


if __name__=='__main__':unittest.main()
