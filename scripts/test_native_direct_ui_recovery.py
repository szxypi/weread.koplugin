#!/usr/bin/env python3
"""Synthetic recovery: no resend after uncertain dispatch or changed state."""
from contextlib import ExitStack,redirect_stdout
from copy import deepcopy
import hashlib
import io
import json
import unittest
from unittest.mock import patch

import resolve_native_direct_ui_trial as recovery
from native_direct_ui_trial_broker import PROTOCOL
from secure_native_direct_ui_trial import NativeDirectUITrialStore
from shelf_flag_change_contract import state_hash
from test_secure_native_session import Backend
from txt_full_summary import digest


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.credentials=dict(vid='900000',deviceId='eink334691225'+'1'*19,
            accessToken='synthetic-access',refreshToken='synthetic-refresh')
        self.before=dict(book_id='41',chapter_uid='2',chapter_idx=3,chapter_offset=12,raw_percent=17,summary='old summary')
        self.target=dict(self.before,chapter_offset=15,summary='new synthetic summary')
        self.counts=dict(readingTime=10,recordReadingTime=20,ttsTime=0)
        self.shelf=dict(books=[dict(bookId='41',secret=0)],archive=[]);self.raw=b'<html><body>synthetic source</body></html>'
        self.plan=dict(protocol=PROTOCOL,owner_sha256=digest('900000'),source_sha256=hashlib.sha256(self.raw).hexdigest(),
            catalog_sha256='a'*64,grant_sha256=digest(self.credentials),shelf_sha256=state_hash(self.shelf),
            baseline=self.before,target=self.target,counts=self.counts,version=1,chapter_progress=None)
        self.store=NativeDirectUITrialStore(Backend());self.receipt=self.store.reserve(self.plan)
        self.current=deepcopy(self.target);self.posts=0;self.mode='ok'

    def advance(self,phase):
        steps=[('prepared','advance_pending'),('advance_pending','advance_acknowledged'),('advance_acknowledged','advance_verified'),
            ('advance_verified','restore_pending'),('restore_pending','restore_acknowledged')]
        for before,after in steps:
            if self.store.read()[0]['phase']==phase:break
            self.receipt=self.store.advance(self.receipt,before,after)

    def run_case(self,*args):
        owner=self
        class Session:
            def load(self):return {'vid':'900000','cookies':{'wr_vid':'900000','wr_skey':'synthetic-web'}}
        class Credentials:
            def load(self,_vid):return dict(owner.credentials)
        class Chapter:
            def __init__(self):self.allowed=set()
            def request(self,*_args,**_kwargs):return {}
        class Web:
            def __init__(self):self.vid=None;self.book_id=None;self.chapter=None
            def set_cookie(self,*_args):pass
            def verify_account(self):pass
            def close(self):pass
            def request(self,*_args,**_kwargs):return owner.shelf
        class Native:
            def __init__(self,*_args,**_kwargs):self.claim=None;self.pending=None
            def request(self,stage,_url,body=None,credentials=None):
                assert credentials==owner.credentials
                if body is not None:
                    assert self.pending==digest(body);self.claim();owner.posts+=1;owner.current=deepcopy(owner.before)
                    return {} if owner.mode=='noack' else {'succ':1}
                if stage=='feature':return {'feature':{}}
                return owner.shelf if stage=='shelf' else {}
        def checked(_web,_native,_credentials,_identity,expected,_counts,_shelf,_web_shelf,previous=None):
            if owner.current==expected:return True
            if previous is not None and owner.current==previous:return False
            raise ValueError('synthetic changed')
        patches=[patch.object(recovery,'NativeDirectUITrialStore',lambda:owner.store),patch.object(recovery,'SessionStore',Session),
            patch.object(recovery,'NativeSessionStore',Credentials),patch.object(recovery,'ChapterProbe',Chapter),
            patch.object(recovery,'WebSourceProbe',Web),patch.object(recovery,'Reads',Native),
            patch.object(recovery,'native_catalog',return_value={'format':'epub','version':1,'chapters':[{'uid':2,'free_or_owned':True}]}),
            patch.object(recovery,'catalog',return_value='a'*64),patch.object(recovery,'current_source',return_value=self.raw),
            patch.object(recovery,'state',side_effect=lambda *_:(deepcopy(owner.current),owner.counts)),
            patch.object(recovery,'check',side_effect=checked),patch.object(recovery.resource,'setrlimit'),
            patch('verify_native_thought_trial.other_pending',return_value=False)]
        with ExitStack() as stack:
            for item in patches:stack.enter_context(item)
            output=stack.enter_context(redirect_stdout(io.StringIO()))
            code=recovery.main(['--saved-session',*args])
        return code,json.loads(output.getvalue())

    def test_prepared_can_be_aborted_without_network(self):
        code,result=self.run_case('--abort-prepared')
        self.assertEqual((code,result['result'],self.posts),(0,'PREPARED_ABORTED',0))
        self.assertEqual(self.store.read()[0]['phase'],'aborted')

    def test_unacknowledged_advance_is_never_replayed(self):
        self.advance('advance_pending');code,result=self.run_case('--restore')
        self.assertEqual((code,result['result'],self.posts),(1,'UNVERIFIED',0))
        self.assertEqual(self.store.read()[0]['phase'],'advance_pending')

    def test_acknowledged_advance_can_restore_after_independent_checks(self):
        self.advance('advance_acknowledged');code,result=self.run_case('--restore')
        self.assertEqual((code,result['result'],self.posts),(0,'ORIGINAL_RESTORED',1))
        self.assertEqual(self.current,self.before);self.assertEqual(self.store.read()[0]['phase'],'retired')

    def test_lost_restore_ack_is_not_sent_twice(self):
        self.advance('advance_acknowledged');self.mode='noack'
        code,result=self.run_case('--restore');self.assertEqual((code,self.posts),(1,1))
        self.assertEqual(self.store.read()[0]['phase'],'restore_pending')
        self.run_case('--restore');self.assertEqual(self.posts,1)

    def test_acknowledged_restore_can_finish_without_write(self):
        self.advance('restore_acknowledged');self.current=deepcopy(self.before)
        code,result=self.run_case('--restore')
        self.assertEqual((code,result['result'],self.posts),(0,'RESTORE_READBACK_VERIFIED',0))
        self.assertEqual(self.store.read()[0]['phase'],'retired')

    def test_unknown_current_point_blocks_restore(self):
        self.advance('advance_acknowledged');self.current['chapter_offset']=999
        code,result=self.run_case('--restore')
        self.assertEqual((code,result['result'],self.posts),(1,'UNVERIFIED',0))
        self.assertEqual(self.store.read()[0]['phase'],'advance_acknowledged')


if __name__=='__main__':unittest.main()
