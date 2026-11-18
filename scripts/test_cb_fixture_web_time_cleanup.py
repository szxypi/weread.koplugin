"""The retained synthetic fixture can be cleaned once, without time replay."""
import copy
from contextlib import redirect_stdout
import hashlib
import io
import json
import unittest
from unittest.mock import patch

from cb_fixture_position import LONG_SUMMARY
from cb_fixture_position_intent import Intent as SeedIntent
from cb_fixture_web_time_intent import Intent as TimeIntent
from synthetic_upload_epub import TEXT
from test_cb_fixture_position_transport import MemoryBackend
import verify_cb_fixture_web_time_cleanup as task


class Cleanup(unittest.TestCase):
    def test_offline_never_reads_session(self):
        with patch.object(task,'SessionStore') as session,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        session.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_preview_apply_and_uncertain_cleanup_are_single_use(self):
        for apply,ack in ((False,True),(True,True),(True,False)):
            with self.subTest(apply=apply,ack=ack):self.run_case(apply,ack)

    def run_case(self,apply,ack):
        owner='900000';target='CB_Synthetic';attempt='a'*32;grant={'vid':owner};saved={'vid':owner,'cookies':{'wr_vid':owner,'wr_skey':'synthetic'}}
        seed=SeedIntent(backend=MemoryBackend());seed.reserve(owner,target,attempt)
        intent=TimeIntent(backend=MemoryBackend());record=intent.reserve(owner,target,attempt,'b'*64);intent.claim(record)
        observation=MemoryBackend();effects={'cleanup':0,'checks':0};point=dict(chapter_uid='9',chapter_idx=1,chapter_offset=44,raw_percent=1,summary=LONG_SUMMARY)
        class Journal:
            def __init__(self):self.value={'phase':'imported','target':target,'attempt':attempt,'plan':{'owner':owner}};self.receipt=object()
            def read(self):return self.value,self.receipt
            def advance(self,receipt,phase):
                assert receipt is self.receipt
                assert (self.value['phase'],phase) in (('imported','cleanup_pending'),('cleanup_pending','restored'))
                self.value['phase']=phase;self.receipt=object();return self.receipt
        class Native:
            def load(self,_owner):return grant
        class Probe:
            def __init__(self,_journal,_grant):self.attempts={'cleanup':0}
            def shelf(self,_grant):return {}
            def cleanup(self,_grant,_receipt):
                self.attempts['cleanup']+=1;effects['cleanup']+=1
                return {'succ':True} if ack else {'succ':False}
        class Web:
            def __init__(self):self.authenticated=False;self.samples=[];self.cookies=[]
            def set_cookie(self,*_args):pass
            def verify_account(self):self.authenticated=True
            def inspect(self,book):
                assert book==target
                return dict(book_id=target,chapter_uid='9',source_format='web_xhtml',source='<p>'+TEXT+'</p>',
                    source_raw_sha256='c'*64,chapters=[dict(chapterUid='9',chapterIdx=1)])
            def close(self):pass
        class Reader(Web):
            def request(self,_stage,_url):return {}
        class NativeRead:
            def __init__(self,_grant,_target):pass
            def progress(self):return {}
            def stats(self):return dict(baseTime=1,readTimes={},totalReadTime=2,readDays=0)
        def check(*_args):effects['checks']+=1
        journal=Journal()
        with patch.object(task,'CbReadingProbe',Web),patch.object(task,'WebSourceProbe',Reader),patch.object(task,'NativeRead',NativeRead),\
             patch.object(task,'position_plan',return_value={'chapter':'9','first':44}),patch.object(task,'position',return_value=point),\
             patch.object(task,'counters',return_value={'readingTime':2,'recordReadingTime':0,'ttsTime':0}),\
             patch.object(task,'check',side_effect=check),patch.object(task,'readback',return_value=ack),\
             patch.object(task,'save_refreshed_web_session',return_value=False):
            report=task.run(saved,None,Native(),grant,journal,seed,intent,observation,apply=apply,probe_factory=Probe)
        self.assertEqual(report['result'],'FIXTURE_REMOVED' if apply and ack else 'READ_ONLY_PREVIEW' if not apply else 'UNVERIFIED')
        self.assertEqual(effects['cleanup'],int(apply));self.assertEqual(report['positive_time_replays'],0)
        self.assertEqual(journal.value['phase'],'restored' if apply and ack else 'cleanup_pending' if apply else 'imported')
        self.assertEqual(observation.load() is not None,apply)
        self.assertNotIn(target,json.dumps(report));self.assertNotIn('wr_skey',json.dumps(report))


if __name__=='__main__':unittest.main()
