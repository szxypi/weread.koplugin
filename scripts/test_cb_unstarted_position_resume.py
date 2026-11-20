from contextlib import redirect_stdout
from copy import deepcopy
import hashlib
import io
import json
import unittest
from unittest.mock import patch

from cb_cloud_position import observed
from cb_fixture_web_time_evidence import Evidence
from cb_fixture_web_time_intent import Intent
from personal_upload_trial import hash_value
from secure_shelf_experiment import canonical
from selection_trial_mock import credentials
from test_cb_fixture_position_transport import MemoryBackend
from verify_readtime_upload import expected_statistics
import verify_cb_unstarted_position_resume as task


class Journal:
    def __init__(self,state):self.state=state;self.receipt=b'owned'
    def read(self):return deepcopy(self.state),self.receipt
    def advance(self,receipt,phase):
        assert receipt==self.receipt
        assert (self.state['phase'],phase) in (('imported','cleanup_pending'),('cleanup_pending','restored'))
        self.state['phase']=phase;self.receipt=phase.encode();return self.receipt


class Receipt:
    def __init__(self):self.backend=MemoryBackend()


class Harness:
    def __init__(self,mode='success'):
        self.mode=mode;self.grant=credentials();self.owner=self.grant['vid'];self.book='CB_ResumeSynthetic';self.attempt='a'*32
        plan={'owner':self.owner,'grant_sha256':hash_value(self.grant)}
        self.journal=Journal(dict(phase='imported',target=self.book,attempt=self.attempt,plan=plan))
        self.receipt=Receipt();self.receipt.backend.save(canonical(dict(schema=1,owner=self.owner,attempt=self.attempt,
            target=self.book,plan_sha256=hash_value(plan))))
        self.time_intent=Intent(backend=MemoryBackend());self.time_evidence=Evidence(backend=MemoryBackend())
        self.position_intent=Intent(backend=MemoryBackend());self.position_evidence=Evidence(backend=MemoryBackend())
        self.position=dict(bookId=self.book,chapterUid=0,chapterOffset=0,progress=0,updateTime=4,
                           readingTime=2,recordReadingTime=0,ttsTime=0)
        self.sample=dict(book_id=self.book,source_format='web_txt',source=task.MARKER,source_raw_sha256='b'*64,chapters=[])
        old_stats=dict(baseTime=0,readTimes={},totalReadTime=0,readDays=0);stamp=1700007203
        projection=observed(self.position,self.book,[],'web')['projection']
        baseline=dict(source='b'*64,position=projection,updated_at=4,counters=dict(readingTime=0,recordReadingTime=0,ttsTime=0),
                      stats=old_stats,body={'books':[dict(bookId=self.book,bookVersion=0,readingTime=2,summary='',
                                                         isResendReadingInfo=1,timestamp=stamp,recordCreateTimeZone='+08:00')]})
        self.time_evidence.save(dict(schema=1,owner_sha256=hashlib.sha256(self.owner.encode()).hexdigest(),
            book_sha256=hashlib.sha256(self.book.encode()).hexdigest(),attempt=self.attempt,baseline=baseline))
        claim=self.time_intent.reserve(self.owner,self.book,self.attempt,hashlib.sha256(canonical(baseline)).hexdigest())
        self.time_intent.claim(claim)
        self.stats=expected_statistics(old_stats,stamp,2,time_zone='+08:00');self.writes=0;self.cleanup=0
    def web_factory(self):
        h=self
        class Web:
            authenticated=False
            def set_cookie(self,*_):pass
            def verify_account(self):self.authenticated=True
            def close(self):pass
            def request(self,stage,_url):return {'data':'stable'} if stage=='shelf' else deepcopy(h.position)
        return Web()
    def source_factory(self):
        h=self
        class Source:
            authenticated=False
            def __init__(self):self.samples={};self.last_checks={}
            def set_cookie(self,*_):pass
            def verify_account(self):self.authenticated=True
            def close(self):pass
            def inspect(self,target):
                assert target==h.book
                self.last_checks=dict(catalog_unchanged=True,versions_unchanged=True,position_unchanged=True)
                return deepcopy(h.sample)
        return Source()
    def native_api(self,_grant,_book):
        h=self
        class Native:
            def progress(self):return deepcopy(h.position)
            def stats(self):return deepcopy(h.stats)
        return Native()
    def upload_factory(self,_journal,_same):
        h=self
        class Upload:
            attempts={'cleanup':0}
            def shelf(self,_grant):return {'data':'stable'}
            def cleanup(self,_grant,receipt):
                assert receipt==b'cleanup_pending' and self.attempts['cleanup']==0
                self.attempts['cleanup']=1;h.cleanup+=1
                return {} if h.mode=='cleanup_noack' else {'succ':1}
        return Upload()
    def inspector(self,_saved,_grant,_target,_current,info,**_kwargs):
        info.update(native_version_category='zero',catalog_root_version_category='absent',catalog_book_version_category='absent');return True
    def position_call(self,context,report,intent,evidence,**kwargs):
        assert context['authority']() and context['shelf_current']() and kwargs['payload_check']({},'',{})
        if kwargs.get('probe_factory') is task.BlockedPositionProbe:
            report['position_posts']=0
            if self.mode=='changed_time':self.time_evidence.backend.save(b'changed')
            return dict(attempted=1,acknowledged=False,cleanup_allowed=False)
        reservation=intent.reserve(self.owner,self.book,self.attempt,'c'*64);intent.claim(reservation)
        self.writes+=1
        if self.mode=='lost':return dict(result='UNVERIFIED',attempted=1,write_uncertain=True,cleanup_allowed=False)
        return dict(result='PASS',attempted=1,write_uncertain=False,cleanup_allowed=True)
    def execute(self,apply=False):
        saved={'vid':self.owner,'cookies':{'wr_vid':self.owner}}
        class NativeStore:
            def load(_self,_owner):return self.grant
        with patch.object(task,'WebSourceProbe',side_effect=self.web_factory),patch.object(task,'CbReadingProbe',side_effect=self.source_factory), \
             patch.object(task,'NativeRead',side_effect=self.native_api),patch.object(task,'save_refreshed_web_session',return_value=False), \
             patch.object(task,'strip_fixture',side_effect=lambda v,_b:v['data']),patch.object(task,'project',side_effect=lambda v:v['data']), \
             patch.object(task,'check_plan',return_value=True),patch.object(task,'inspect_fixture',side_effect=self.inspector), \
             patch.object(task,'readback',return_value=True),patch.object(task,'lua_check',return_value=True):
            return task.run(saved,None,NativeStore(),self.grant,self.journal,self.receipt,self.time_intent,self.time_evidence,
                            self.position_intent,self.position_evidence,apply=apply,position=self.position_call,
                            upload_factory=self.upload_factory,sleep=lambda _:None,lua_command=['synthetic'])


class ResumeTest(unittest.TestCase):
    def test_dry_run_cannot_write_and_does_not_claim(self):
        h=Harness();result=h.execute()
        self.assertEqual(result['result'],'READ_ONLY_PREVIEW',result);self.assertEqual((h.writes,h.cleanup),(0,0))
        self.assertIsNone(h.position_intent.backend.load());self.assertEqual(h.journal.state['phase'],'imported')

    def test_success_is_one_position_and_one_cleanup(self):
        h=Harness();result=h.execute(True)
        self.assertEqual(result['result'],'FIRST_POSITION_WITH_TIME_VERIFIED',result)
        self.assertEqual((h.writes,h.cleanup),(1,1));self.assertEqual(h.journal.state['phase'],'restored')
        self.assertEqual(h.execute(True)['result'],'UNVERIFIED');self.assertEqual((h.writes,h.cleanup),(1,1))

    def test_unknown_position_retains_fixture_and_prevents_replay(self):
        h=Harness('lost');result=h.execute(True)
        self.assertEqual(result['result'],'UNVERIFIED');self.assertTrue(result['position_write_uncertain'])
        self.assertEqual((h.writes,h.cleanup),(1,0));self.assertEqual(h.journal.state['phase'],'imported')
        self.assertEqual(h.execute(True)['result'],'UNVERIFIED');self.assertEqual(h.writes,1)

    def test_unknown_cleanup_never_retries(self):
        h=Harness('cleanup_noack');result=h.execute(True)
        self.assertEqual(result['result'],'UNVERIFIED');self.assertTrue(result['cleanup_uncertain'])
        self.assertEqual((h.writes,h.cleanup),(1,1));self.assertEqual(h.journal.state['phase'],'cleanup_pending')
        self.assertEqual(h.execute(True)['result'],'UNVERIFIED');self.assertEqual(h.cleanup,1)

    def test_changed_time_record_stops_before_position(self):
        h=Harness('changed_time');result=h.execute(True)
        self.assertEqual(result['result'],'UNVERIFIED');self.assertEqual((h.writes,h.cleanup),(0,0))

    def test_invalid_receipt_and_existing_position_claim_stop(self):
        h=Harness();h.receipt.backend.save(b'wrong');self.assertEqual(h.execute(True)['result'],'UNVERIFIED')
        h=Harness();h.position_intent.backend.save(b'existing');self.assertEqual(h.execute(True)['result'],'UNVERIFIED')
        self.assertEqual((h.writes,h.cleanup),(0,0))

    def test_offline_default_does_not_read_credentials(self):
        with patch.object(task,'SessionStore',side_effect=AssertionError),redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')


if __name__=='__main__':unittest.main()
