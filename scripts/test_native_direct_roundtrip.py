#!/usr/bin/env python3
"""Offline tests for the bounded native XHTML round-trip supervisor."""
import contextlib
import io
import json
import unittest
from unittest.mock import patch

import verify_native_direct_roundtrip as trial
from test_secure_native_session import Backend


class TrialTests(unittest.TestCase):
    def setUp(self):
        self.raw=('<html><body><p>Unique beginning of this synthetic chapter with diverse words and characters '
                  'for verifying the source boundary and a bounded excerpt.</p></body></html>').encode()
        self.before=dict(book_id='41',chapter_uid='2',chapter_idx=3,chapter_offset=1000,
            raw_percent=17,summary='Original cloud summary')
        self.creds=dict(vid='900000',deviceId='eink334691225'+'1'*19,
            accessToken='synthetic-access',refreshToken='synthetic-refresh')
        self.shelf={'books':[{'bookId':'41','secret':0,'finishReading':0}],'archive':[]}
        self.point=dict(self.before);self.posts=[];self.mode='ok'
        self.store=trial.DirectTrialStore(Backend())

    def test_selection_and_binding_are_bounded(self):
        target=trial.select_target(self.raw,self.before)
        self.assertNotEqual(target['chapter_offset'],self.before['chapter_offset'])
        self.assertEqual(len(target['summary']),20)
        self.assertFalse(any(c.isspace() for c in target['summary']))
        duplicate=b'<html><body><p>'+b'abcdefghijklmno'*12+b'</p><p>'+b'abcdefghijklmno'*12+b'</p></body></html>'
        with self.assertRaises(ValueError):trial.select_target(duplicate,self.before)

    def run_case(self,mode,apply=True):
        self.mode=mode;owner=self
        class Store:
            def load(self):return {'vid':'900000','cookies':{'wr_vid':'900000','wr_skey':'synthetic-web'}}
        class Credentials:
            def load(self,_vid):return dict(owner.creds)
        class Chapter:
            def inspect(self,_credentials,_offset):
                return ({'book_id':'41','expected':{'format':'epub','version':1,'chapters':[
                    {'uid':2,'wordCount':300,'free_or_owned':True}]}},None,None)
        class Native:
            def __init__(self,_credentials,_identity):self.claim=None;self.pending=None
            def request(self,stage,url,body=None,credentials=None):
                self.assertion(credentials==owner.creds)
                if body is not None:
                    self.assertion(self.pending==trial.digest(body) and len(owner.posts)<2)
                    self.claim();owner.posts.append(stage)
                    owner.point=dict(book_id='41',chapter_uid=str(body['chapterUid']),chapter_idx=body['chapterIdx'],
                        chapter_offset=body['chapterOffset'],raw_percent=body['currentProgress'],summary=body['summary'])
                    return {} if owner.mode=='lost_ack' else {'succ':1}
                if url.endswith('/shelf/sync'):return owner.shelf
                if url.endswith('/feature?synckey=0'):return {'feature':{}}
                if owner.mode=='changed' and len(owner.posts)==1:return owner.progress(offset_change=1)
                return owner.progress()
            @staticmethod
            def assertion(value):
                if not value:raise AssertionError('mock scope')
        class Web:
            def __init__(self):self.vid=None;self.book_id=None;self.chapter=None
            def set_cookie(self,*_args):pass
            def verify_account(self):pass
            def close(self):pass
            def request(self,stage,_url,body=None):
                if stage=='shelf':return owner.shelf
                if stage=='catalog_before':return {'data':[{'bookId':'41','updated':[{'chapterUid':2,'chapterIdx':3}]}]}
                value=owner.progress()
                if owner.mode=='web_summary_changed':value['summary']='Unexpected cloud summary'
                return value
        patches=[patch.object(trial,'SessionStore',Store),patch.object(trial,'NativeSessionStore',Credentials),
            patch.object(trial,'ChapterProbe',Chapter),patch.object(trial,'Reads',Native),patch.object(trial,'WebSourceProbe',Web),
            patch.object(trial,'DirectTrialStore',lambda:owner.store),patch.object(trial,'current_source',return_value=self.raw),
            patch.object(trial.resource,'setrlimit'),patch('verify_native_thought_trial.other_pending',return_value=False)]
        with contextlib.ExitStack() as stack:
            for item in patches:stack.enter_context(item)
            output=stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            code=trial.main(['--saved-session']+(['--apply'] if apply else []))
        return code,json.loads(output.getvalue())

    def progress(self,offset_change=0):
        point=self.point
        return dict(bookId='41',chapterUid=int(point['chapter_uid']),chapterIdx=point['chapter_idx'],
            chapterOffset=point['chapter_offset']+offset_change,progress=point['raw_percent'],summary=point['summary'],
            readingTime=10,recordReadingTime=20,ttsTime=0)

    def test_dry_run_has_no_intent_or_writes(self):
        code,result=self.run_case('ok',False)
        self.assertEqual((code,result['result'],self.posts),(0,'READ_ONLY_READY',[]))
        self.assertIsNone(self.store.read()[0])

    def test_two_successful_writes_restore_the_original(self):
        code,result=self.run_case('ok')
        self.assertEqual((code,result['result'],len(self.posts)),(0,'NATIVE_XHTML_ROUNDTRIP_VERIFIED',2))
        self.assertEqual(self.point,self.before)
        self.assertEqual(self.store.read()[0]['phase'],'retired')
        self.assertNotIn(self.before['summary'],json.dumps(result))

    def test_missing_receipt_never_retries_or_restores(self):
        code,result=self.run_case('lost_ack')
        self.assertEqual((code,result['result'],len(self.posts)),(1,'UNVERIFIED',1))
        self.assertEqual(self.store.read()[0]['phase'],'advance_pending')
        self.assertEqual(result['account_data_posts'],1)

    def test_inconsistent_readback_stops_before_restore(self):
        code,result=self.run_case('changed')
        self.assertEqual((code,result['result'],len(self.posts)),(1,'UNVERIFIED',1))
        self.assertEqual(self.store.read()[0]['phase'],'advance_acknowledged')

    def test_inconsistent_baseline_never_claims_or_writes(self):
        code,result=self.run_case('web_summary_changed')
        self.assertEqual((code,result['result'],self.posts),(1,'UNVERIFIED',[]))
        self.assertIsNone(self.store.read()[0])


if __name__=='__main__':unittest.main()
