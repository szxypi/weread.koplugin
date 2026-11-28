"""Audit-bound cleanup never replays the native time request."""
import hashlib,json,unittest
from unittest.mock import patch
from cb_fixture_position_intent import Intent as SeedIntent
from cb_fixture_web_time_intent import Intent as TimeIntent
from synthetic_upload_epub import TEXT
from test_cb_fixture_position_transport import MemoryBackend
from verify_position_roundtrip import canonical
import verify_cb_fixture_native_batch_cleanup as task


class Cleanup(unittest.TestCase):
    def test_preview_apply_and_unknown_cleanup(self):
        for apply,ack in ((False,True),(True,True),(True,False)):
            with self.subTest(apply=apply,ack=ack):self.run_case(apply,ack)
    def run_case(self,apply,ack):
        owner='900000';target='CB_Synthetic';attempt='a'*32;grant={'vid':owner};saved={'vid':owner,'cookies':{'wr_vid':owner}}
        seed=SeedIntent(backend=MemoryBackend());seed.reserve(owner,target,attempt)
        point=dict(chapter_uid='9',chapter_idx=1,chapter_offset=44,raw_percent=1,summary='initial')
        stats=dict(baseTime=1700000000,readTimes={},totalReadTime=0,readDays=0)
        baseline=dict(source='c'*64,position=point,updated_at=1,counters=dict(readingTime=0,recordReadingTime=0,ttsTime=0),
            stats=stats,body={'books':[dict(bookId=target,readingTime=2,timestamp=1700000010,hours=[dict(readingTime=2,timeZone='+08:00')])]})
        digest=hashlib.sha256(canonical(baseline).encode()).hexdigest()
        intent=TimeIntent(backend=MemoryBackend());rec=intent.reserve(owner,target,attempt,digest);intent.claim(rec)
        evidence={'attempt':attempt,'owner_sha256':hashlib.sha256(owner.encode()).hexdigest(),
                  'book_sha256':hashlib.sha256(target.encode()).hexdigest(),'baseline':baseline}
        evidence_backend=MemoryBackend();evidence_backend.save(json.dumps(evidence).encode());observation=MemoryBackend();effects={'cleanup':0}
        class Journal:
            def __init__(self):self.value={'phase':'imported','target':target,'attempt':attempt,'plan':{'owner':owner}};self.receipt=object()
            def read(self):return self.value,self.receipt
            def advance(self,receipt,phase):
                assert receipt is self.receipt and (self.value['phase'],phase) in (('imported','cleanup_pending'),('cleanup_pending','restored'))
                self.value['phase']=phase;self.receipt=object();return self.receipt
        class Native:
            def load(self,_owner):return grant
        class Probe:
            def __init__(self,_journal,_grant):self.attempts={'cleanup':0}
            def shelf(self,_grant):return {}
            def cleanup(self,_grant,_receipt):self.attempts['cleanup']+=1;effects['cleanup']+=1;return {'succ':ack}
        class Web:
            def __init__(self):self.authenticated=False;self.samples=[];self.cookies=[]
            def set_cookie(self,*_args):pass
            def verify_account(self):self.authenticated=True
            def inspect(self,_book):return dict(book_id=target,chapter_uid='9',source_format='web_xhtml',source='<p>'+TEXT+'</p>',source_raw_sha256='c'*64,chapters=[])
            def close(self):pass
        class Reader(Web):
            def request(self,_stage,_url):return {}
        class NativeRead:
            def __init__(self,_grant,_book):pass
            def progress(self):return {}
            def stats(self):return dict(stats,totalReadTime=2)
        state=dict(point,kind='located',summary_present=False,summary='')
        journal=Journal()
        with patch.object(task,'backend',return_value=evidence_backend),patch.object(task,'CbReadingProbe',Web),\
             patch.object(task,'WebSourceProbe',Reader),patch.object(task,'NativeRead',NativeRead),\
             patch.object(task,'state',return_value=state),patch.object(task,'counters',return_value={'readingTime':2,'recordReadingTime':0,'ttsTime':0}),\
             patch.object(task,'expected_statistics',return_value=dict(stats,totalReadTime=2)),patch.object(task,'compare',return_value={}),\
             patch.object(task,'check'),patch.object(task,'readback',return_value=ack),patch.object(task,'save_refreshed_web_session',return_value=False):
            result=task.run(saved,None,Native(),grant,journal,seed,intent,observation,apply=apply,probe_factory=Probe)
        expected='READ_ONLY_PREVIEW' if not apply else 'FIXTURE_REMOVED' if ack else 'UNVERIFIED'
        self.assertEqual(result['result'],expected);self.assertEqual(effects['cleanup'],int(apply));self.assertEqual(result['positive_time_replays'],0)
        self.assertEqual(journal.value['phase'],'imported' if not apply else 'restored' if ack else 'cleanup_pending')
        self.assertEqual(observation.load() is not None,apply)


if __name__=='__main__':unittest.main()
