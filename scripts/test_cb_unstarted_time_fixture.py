"""Closed synthetic integration of unstarted time fixture, with no network."""
from contextlib import redirect_stdout
from copy import deepcopy
import io
import json
import unittest
from unittest.mock import patch

from cb_fixture_web_time_evidence import Evidence
from cb_fixture_web_time_intent import Intent
from personal_upload_trial import hash_value
from secure_shelf_experiment import canonical
from selection_trial_mock import credentials
from test_cb_fixture_position_transport import MemoryBackend
from verify_readtime_upload import expected_statistics
import verify_cb_unstarted_time_fixture as task


class Journal:
    def __init__(self): self.state=None; self.receipt=b'synthetic-upload-receipt'
    def read(self): return self.state,self.receipt if self.state else None


class Receipt:
    def __init__(self): self.backend=MemoryBackend()
    def record(self,*args): raise AssertionError('simulated uploader controls receipt')


class Harness:
    def __init__(self, mode='success'):
        self.mode=mode;self.grant=credentials();self.owner=self.grant['vid'];self.target='CB_SyntheticFixture'
        self.clock=1700007200.2;self.journal=Journal();self.receipt=Receipt()
        self.intent=Intent(backend=MemoryBackend());self.evidence=Evidence(backend=MemoryBackend())
        self.sample=dict(book_id=self.target,source_format='web_txt',source=task.MARKER,source_raw_sha256='b'*64,
                         baseline=dict(chapter='0',offset=0,percent=0),chapters=[])
        self.position=dict(bookId=self.target,chapterUid=0,chapterOffset=0,progress=0,updateTime=10,
                           readingTime=0,recordReadingTime=0,ttsTime=0)
        self.stats_value=dict(baseTime=0,readTimes={},totalReadTime=0,readDays=0)
        self.cleaned=False;self.sent=0;self.api=None;self.uploads=0
    def sleep(self,seconds): self.clock+=seconds
    def web_factory(self):
        fixture=self
        class Web:
            authenticated=False
            def set_cookie(self,*_):pass
            def verify_account(self):self.authenticated=True
            def close(self):pass
            def request(self,stage,_url):
                if stage=='shelf':return {'data':'stable'}
                assert stage=='progress_after'
                return deepcopy(fixture.position)
        return Web()
    def source_factory(self):
        fixture=self
        class Source:
            authenticated=False
            def __init__(self):self.samples={};self.last_checks={}
            def set_cookie(self,*_):pass
            def verify_account(self):self.authenticated=True
            def close(self):pass
            def inspect(self,target):
                assert target==fixture.target
                self.last_checks=dict(catalog_unchanged=True,versions_unchanged=True,position_unchanged=True)
                return deepcopy(fixture.sample)
        return Source()
    def api_factory(self,grant,target,authority):
        fixture=self
        class Api:
            sent=0
            def progress(self):return deepcopy(fixture.position)
            def stats(self):return deepcopy(fixture.stats_value)
            def capability(self,name):return {'token':'synthetic-config'} if name=='config' else {'feature':{}}
            def bind(self,payload,summary):
                assert summary=='' and payload['books'][0]['bookId']==target and payload['books'][0]['bookVersion']==0
                self.expected=deepcopy(payload)
            def send_once(self,payload,permit):
                assert payload==self.expected and permit() and authority() and self.sent==0
                self.sent+=1;fixture.sent+=1;fixture.position['readingTime']=2
                fixture.stats_value=expected_statistics(fixture.stats_value,int(fixture.clock)-2,2,time_zone='+08:00')
                if fixture.mode=='changed_position':fixture.position['chapterUid']=1
                if fixture.mode=='lost':raise TimeoutError()
                return {} if fixture.mode=='no_ack' else {'succ':1}
        self.api=Api();return self.api
    def inspector(self,_saved,_grant,target,_current,summary,*,expected_source):
        assert target==self.target and expected_source=='b'*64
        summary.update(native_version_category='zero',catalog_root_version_category='absent',catalog_book_version_category='absent')
        if self.mode=='wrong_version':summary['native_version_category']='positive'
        return True
    def uploader(self,_probe,journal,grant,grant_check,source,*,apply,cleanup_gate,**kwargs):
        assert kwargs['fixture_extension']=='txt' and kwargs['fixture_builder']()==task.BODY and grant_check(grant)
        if not apply:return {'result':'READ_ONLY_PREVIEW','phase':'preview'}
        self.uploads+=1
        plan={'owner':self.owner};journal.state=dict(phase='imported',target=self.target,attempt='a'*32,plan=plan)
        self.receipt.backend.data=canonical(dict(schema=1,owner=self.owner,attempt='a'*32,target=self.target,plan_sha256=hash_value(plan)))
        assert source(self.target)
        allowed=cleanup_gate(journal,journal.receipt,plan,self.target)
        if allowed:self.cleaned=True;journal.state['phase']='restored'
        return dict(result='TXT_IMPORT_AND_SOURCE_VERIFIED' if allowed else 'UNVERIFIED',phase='restored' if allowed else 'imported',
                    cos_put_attempts=1,notify_posts=1,cleanup_posts=int(allowed))
    def execute(self,apply=True,after_time=None):
        saved={'vid':self.owner,'cookies':{'wr_vid':self.owner}}
        class Native:
            def load(_self,_owner):return self.grant
        with patch.object(task,'WebSourceProbe',side_effect=self.web_factory), patch.object(task,'CbReadingProbe',side_effect=self.source_factory), \
             patch.object(task,'save_refreshed_web_session',return_value=False), patch.object(task,'project',side_effect=lambda v:v['data']), \
             patch.object(task,'strip_fixture',side_effect=lambda v,_target:v['data']), patch.object(task,'local_zone',return_value='+08:00'):
            return task.run(saved,None,Native(),self.grant,self.journal,self.receipt,self.intent,self.evidence,apply=apply,
                            upload_factory=lambda *_:object(),uploader=self.uploader,api_factory=self.api_factory,inspector=self.inspector,
                            clock=lambda:self.clock,monotonic=lambda:self.clock,sleep=self.sleep,random=lambda _:123,after_time=after_time)


class FixtureTest(unittest.TestCase):
    def test_offline_default_does_not_load_credentials(self):
        with patch.object(task,'SessionStore',side_effect=AssertionError),redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_full_synthetic_flow_and_one_time_scope(self):
        h=Harness();result=h.execute()
        self.assertEqual(result['result'],'UNSTARTED_TIME_FIXTURE_VERIFIED',result)
        self.assertEqual((h.sent,h.uploads,result['account_data_writes_known']),(1,1,4))
        self.assertTrue(h.cleaned and result['time_probe']['no_chapter_and_counts_verified'])
        self.assertFalse(result['time_write_uncertain']);self.assertEqual(h.execute()['result'],'UNVERIFIED')
        self.assertEqual((h.sent,h.uploads),(1,1))

    def test_lost_and_unexpected_outcomes_retain_fixture(self):
        for mode in ('lost','no_ack','changed_position'):
            h=Harness(mode);result=h.execute()
            self.assertEqual(result['result'],'UNVERIFIED',result);self.assertEqual(h.sent,1)
            self.assertTrue(result['time_write_uncertain']);self.assertFalse(h.cleaned)
            self.assertEqual(h.execute()['result'],'UNVERIFIED');self.assertEqual(h.sent,1)

    def test_version_mismatch_has_no_time_request_and_cleans_fixture(self):
        h=Harness('wrong_version');result=h.execute()
        self.assertEqual(result['result'],'UNVERIFIED');self.assertEqual(h.sent,0);self.assertTrue(h.cleaned)

    def test_followup_only_after_verified_time_and_unknown_retains_fixture(self):
        h=Harness();calls=[]
        def uncertain(context,_report):
            self.assertEqual(context['pair']()['native']['counters']['readingTime']['value'],2)
            self.assertTrue(context['authority']() and context['shelf_current']());calls.append(1)
            return dict(attempted=1,write_uncertain=True,cleanup_allowed=False)
        result=h.execute(after_time=uncertain)
        self.assertEqual(result['result'],'UNVERIFIED');self.assertEqual(calls,[1])
        self.assertEqual(result['position_posts'],1);self.assertTrue(result['position_write_uncertain']);self.assertFalse(h.cleaned)
        h=Harness('lost');calls=[];result=h.execute(after_time=lambda *_:calls.append(1))
        self.assertFalse(calls);self.assertFalse(h.cleaned);self.assertTrue(result['time_write_uncertain'])

    def test_preflight_never_imports_or_reserves(self):
        h=Harness();result=h.execute(False)
        self.assertEqual(result['result'],'READ_ONLY_PREVIEW');self.assertEqual((h.uploads,h.sent),(0,0))
        self.assertIsNone(h.intent.backend.load());self.assertIsNone(h.evidence.backend.load())


if __name__=='__main__':unittest.main()
