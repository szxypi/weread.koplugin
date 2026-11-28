#!/usr/bin/env python3
"""Offline tests for first-position UI supervision and one-shot recovery."""
from copy import deepcopy
import hashlib
import time
import unittest
from unittest.mock import patch

from native_direct_initial_ui_broker import bind_metadata,execute
from native_direct_time_trial_store import Intent
from native_time_capture_evidence import account_key
from native_txt_read_model import body
from readtime_upload_model import guest_token
from test_secure_native_session import Backend,credentials
from verify_source_coordinates import FilteredSource


class BrokerTests(unittest.TestCase):
    def setUp(self):
        self.raw=b'<html><body><p>Unique synthetic source words for checking the exact reader location and its summary.</p></body></html>'
        model=FilteredSource(self.raw.decode());visible=[i for i,c in enumerate(model.characters) if not c.isspace()]
        text=''.join(model.characters[i] for i in visible);index=4
        baseline=dict(kind='no_chapter',book_id='41',chapter_uid='0',chapter_offset=0,raw_percent=0,index_present=False,summary_present=False)
        target=dict(book_id='41',chapter_uid='2',chapter_idx=3,chapter_offset=model.starts[visible[index]],raw_percent=0,summary=text[index:index+20])
        self.expected=dict(book_id='41',uid='2',chapter_idx=3,native_before=baseline,counts=dict(readingTime=2,recordReadingTime=0,ttsTime=0),
            version=1,native_shelf='a'*64,source_sha256=hashlib.sha256(self.raw).hexdigest())
        self.metadata=dict(book_id='41',before=baseline,desired=target,counts=self.expected['counts'],version=1,
            shelf_sha256='a'*64,source_sha256=self.expected['source_sha256'],file_id='c'*64,basis='filtered_xhtml_utf16')
        self.anchor=dict(text=text,point_offset=index);self.creds=credentials();self.guest=guest_token({'feature':{}})[0]
        self.store=Intent(backend=Backend());self.report=dict(account_data_posts=0,dispatch_may_have_occurred=False)
        self.checks=[]
    def plan(self):return ('STEP',dict(kind='plan',metadata=deepcopy(self.metadata),anchor=deepcopy(self.anchor)))
    def claim(self):
        record=dict(phase='pending',account=account_key(self.creds['vid']),metadata=deepcopy(self.metadata))
        request=body(self.creds,self.metadata['desired'],1,self.guest,int(time.time()),123,'+08:00')
        return ('STEP',dict(kind='claim',body=request,selection=deepcopy(self.metadata),record=record))
    def result(self,armed):return ('RESULT',dict(result='INITIAL_UI_VERIFIED' if armed else 'DRY_BLOCKED',profile_removed=True))
    def run_frames(self,frames,armed=True,after=None,current=None):
        class Child:
            stdin=object();stdout=object()
            def wait(self,timeout=None):return 0
            def poll(self):return None
        class Source:
            def __init__(self,*args,**kwargs):self.frames=iter(frames)
            def next(self):return next(self.frames)
        def before(_):self.checks.append('before');return True
        def checked(_):
            self.checks.append('after')
            if after:after()
            return True
        payload=dict(armed=armed,expected=self.expected,token='a'*32,credentials=self.creds,guest=self.guest,time_zone='+08:00')
        with patch('native_direct_initial_ui_broker.subprocess.Popen',return_value=Child()), \
             patch('native_direct_initial_ui_broker.Frames',Source),patch('native_direct_initial_ui_broker.write_initial'), \
             patch('native_direct_initial_ui_broker.reply'),patch('native_direct_initial_ui_broker.stop'):
            execute(payload,['synthetic'],self.store,self.raw,self.report,current=current or (lambda:True),before=before,after=checked)
    def test_dry_is_read_only(self):
        self.run_frames([self.plan(),self.claim(),self.result(False)],False)
        self.assertEqual(self.store.read(),(None,None));self.assertEqual(self.report['account_data_posts'],0)
        self.assertEqual(self.report['result'],'INITIAL_NATIVE_UI_DRY_VERIFIED')
    def test_one_write_verified_and_never_replayed(self):
        frames=[self.plan(),self.claim(),('STEP',dict(kind='ack',status=200,response={'succ':1})),('STEP',dict(kind='verified')),self.result(True)]
        self.run_frames(frames);self.assertEqual(self.store.read()[0]['phase'],'verified')
        self.assertEqual(self.report['account_data_posts'],1);self.assertEqual(self.checks,['before','before','after'])
        with self.assertRaises(ValueError):self.run_frames(frames)
    def test_unconfirmed_receipt_stays_claimed_and_blocks_replay(self):
        frames=[self.plan(),self.claim(),('STEP',dict(kind='ack',status=200,response={}))]
        with self.assertRaises(ValueError):self.run_frames(frames)
        self.assertEqual(self.store.read()[0]['phase'],'claimed');self.assertIsNone(self.report['account_data_posts'])
        with self.assertRaises(ValueError):self.run_frames(frames)
    def test_failed_readback_preserves_acknowledgement(self):
        frames=[self.plan(),self.claim(),('STEP',dict(kind='ack',status=200,response={'succ':1})),('STEP',dict(kind='verified'))]
        with self.assertRaises(ValueError):self.run_frames(frames,after=lambda:(_ for _ in ()).throw(ValueError('changed')))
        self.assertEqual(self.store.read()[0]['phase'],'acknowledged')
    def test_source_and_body_tampering_rejected_before_claim(self):
        changed=deepcopy(self.metadata);changed['desired']['summary']='wrong'
        with self.assertRaises(ValueError):bind_metadata(changed,self.anchor,self.expected,self.raw)
        claim=self.claim();claim[1]['body']['readingTime']=1
        with self.assertRaises(ValueError):self.run_frames([self.plan(),claim])
        self.assertEqual(self.store.read(),(None,None))
    def test_wrong_owner_and_duplicate_claim_rejected(self):
        claim=self.claim();claim[1]['record']['account']='wrong'
        with self.assertRaises(ValueError):self.run_frames([self.plan(),claim])
        self.assertEqual(self.store.read(),(None,None))
        claim=self.claim()
        with self.assertRaises(ValueError):self.run_frames([self.plan(),claim,claim])
        self.assertEqual(self.store.read()[0]['phase'],'claimed')
    def test_changed_account_prevents_write(self):
        def changed():raise ValueError('account changed')
        with self.assertRaises(ValueError):self.run_frames([self.plan(),self.claim()],current=changed)
        with self.assertRaises(ValueError):self.run_frames([self.plan(),self.claim()],current=lambda:False)
        self.assertEqual(self.store.read(),(None,None))
    def test_false_readback_does_not_mark_verified(self):
        frames=[self.plan(),self.claim(),('STEP',dict(kind='ack',status=200,response={'succ':1})),('STEP',dict(kind='verified'))]
        with patch('native_direct_initial_ui_broker.subprocess.Popen') as process:
            process.return_value.stdin=object();process.return_value.stdout=object();process.return_value.poll.return_value=None
            class Source:
                def __init__(self,*args,**kwargs):self.frames=iter(frames)
                def next(self):return next(self.frames)
            payload=dict(armed=True,expected=self.expected,token='a'*32,credentials=self.creds,guest=self.guest,time_zone='+08:00')
            with patch('native_direct_initial_ui_broker.Frames',Source),patch('native_direct_initial_ui_broker.write_initial'), \
                 patch('native_direct_initial_ui_broker.reply'),patch('native_direct_initial_ui_broker.stop'):
                with self.assertRaisesRegex(ValueError,'initial_ui/snapshot'):
                    execute(payload,['synthetic'],self.store,self.raw,self.report,current=lambda:True,before=lambda _:True,after=lambda _:False)
        self.assertEqual(self.store.read()[0]['phase'],'acknowledged')


if __name__=='__main__':unittest.main()
