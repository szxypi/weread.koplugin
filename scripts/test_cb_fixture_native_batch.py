"""One-shot fixture native batch accounting test with no live service calls."""
import copy
from contextlib import redirect_stdout
import hashlib
import io
import json
import unittest
from unittest.mock import patch

from cb_fixture_position import LONG_SUMMARY,plan as fixture_plan
from cb_fixture_position_intent import Intent as SeedIntent
from cb_fixture_web_time_intent import Intent as TimeIntent
from cb_fixture_web_time_evidence import Evidence
from test_cb_fixture_position import fixture
from test_cb_fixture_position_transport import MemoryBackend
from verify_native_statistics import period
from verify_readtime_upload import expected_statistics
import verify_cb_fixture_native_batch as task


class FixtureTimeTrial(unittest.TestCase):
    def test_offline_does_not_open_sessions(self):
        with patch.object(task,'SessionStore') as store,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]),0)
        store.assert_not_called();self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def test_claim_has_one_use_and_other_fixture_is_rejected(self):
        store=TimeIntent(backend=MemoryBackend());record=store.reserve('900000','CB_Synthetic','a'*32,'b'*64)
        receipt=store.claim(record);self.assertTrue(store.verify(record,receipt))
        with self.assertRaises(Exception):store.claim(record)
        with self.assertRaises(Exception):store.reserve('900000','CB_Other','c'*32,'d'*64)

    def test_success_and_uncertain_result_gate_cleanup(self):
        for success in (True,False):
            with self.subTest(success=success):self.run_trial(success)

    def run_trial(self,success):
        target,sample=fixture();sample['source_raw_sha256']=hashlib.sha256(sample['source'].encode()).hexdigest()
        plan=fixture_plan(target,sample);owner='900000';grant=dict(vid=owner)
        saved=dict(vid=owner,cookies={'wr_vid':owner,'wr_skey':'synthetic-session'})
        wall=[task.time.time()];month=period('monthly',wall[0])[0]
        day=int((wall[0]+28800)//86400*86400-28800)
        state={'raw':dict(book=dict(bookId=target,chapterUid=9,chapterIdx=1,chapterOffset=plan['first'],progress=1,
                                  summary=LONG_SUMMARY,updateTime=123,readingTime=0,recordReadingTime=0,ttsTime=0)),
               'stats':dict(baseTime=month,readTimes={str(day):0},totalReadTime=0,readDays=0),'posts':0}
        class Journal:
            def __init__(self):self.data=dict(phase='imported',target=target,attempt='a'*32,plan=dict(owner=owner));self.receipt=object()
            def read(self):return self.data,self.receipt
        class Native:
            def load(self,_owner):return grant
        class Base:
            def __init__(self,*_args):
                self.authenticated=False;self.samples=[];self.progress={};self.last_checks=dict(catalog_unchanged=True,versions_unchanged=True,position_unchanged=True)
            def set_cookie(self,*_args):pass
            def verify_account(self):self.authenticated=True
            def close(self):pass
            def inspect(self,book):assert book==target;return copy.deepcopy(sample)
        class Web(Base):
            def inspect(self,book):
                result=super().inspect(book);self.progress[(book,'progress_before')]=copy.deepcopy(state['raw']);return result
        class Seed(Base):
            def __init__(self,_plan,_owner,authority):super().__init__();self.authority=authority
            def execute(self,_baseline):assert self.authority();return dict(result='PASS',writes=4)
        class Read:
            def __init__(self,_grant,_book):self.sent=0
            def progress(self):return copy.deepcopy(state['raw'])
            def stats(self):return copy.deepcopy(state['stats'])
            def info(self):return dict(bookId=target,bookVersion=3)
            def config(self):return dict(token='synthetic')
            def feature(self):return dict(feature={})
            def send_once(self,payload,authority):
                assert authority() and not self.sent;self.sent=1;state['posts']+=1
                if not success:return {'succ':False}
                state['raw']['book']['readingTime']+=2
                state['stats']=expected_statistics(state['stats'],payload['start'],2)
                return {'succ':True}
        class Time(Base):
            def request(self,stage,_url,*_args):
                if stage=='catalog_before':return {}
                return copy.deepcopy(state['raw'])
        seed=SeedIntent(backend=MemoryBackend());time_intent=TimeIntent(backend=MemoryBackend());journal=Journal()
        def fake_upload(_probe,provided,_grant,_same,read_source,*,apply,cleanup_gate):
            self.assertTrue(apply);self.assertIs(provided,journal);self.assertTrue(read_source(target))
            allowed=cleanup_gate(journal,journal.receipt,journal.data['plan'],target)
            self.assertEqual(allowed,success)
            return dict(result='EPUB_IMPORT_AND_SOURCE_VERIFIED' if allowed else 'UNVERIFIED',phase='restored' if allowed else 'imported',
                        cos_put_attempts=1,notify_posts=1,cleanup_posts=int(allowed))
        def sleep(seconds):wall[0]+=seconds
        with patch.object(task,'CbReadingProbe',Base),patch.object(task,'Web',Web),patch.object(task,'SeedProbe',Seed),\
             patch.object(task,'BatchProbe',Read),patch.object(task,'WebSourceProbe',Time),patch.object(task,'save_refreshed_web_session',return_value=False),\
             patch.object(task,'normalize_chapter_infos',return_value=({'bookVersion':3},[])),\
             patch.object(task,'build_batch',side_effect=lambda _grant,_book,rows,*args,**kwargs:{'start':rows[0]['start_time']}),\
             patch.object(task.time,'time',side_effect=lambda:wall[0]),patch.object(task.time,'monotonic',side_effect=lambda:wall[0]),\
             patch.object(task.time,'sleep',side_effect=sleep):
            result=task.run(saved,None,Native(),grant,journal,seed,time_intent,evidence=Evidence(backend=MemoryBackend()),apply=True,upload_factory=lambda *_:None,upload_run=fake_upload)
        self.assertEqual(result['result'],'FIXTURE_NATIVE_BATCH_VERIFIED' if success else 'UNVERIFIED')
        self.assertEqual(result['positive_time_posts'],1);self.assertEqual(state['posts'],1)
        self.assertNotIn(target,json.dumps(result));self.assertNotIn('synthetic-session',json.dumps(result))
        with self.assertRaises(Exception):time_intent.reserve(owner,target,'a'*32,'b'*64)


if __name__=='__main__':unittest.main()
