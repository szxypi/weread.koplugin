"""Only an exact fixture with zero claimed UI sends can be removed."""
import hashlib
import unittest
from unittest.mock import patch
from cb_fixture_position import LONG_SUMMARY
from cb_fixture_position_intent import Intent as SeedIntent
from cb_fixture_native_time_intent import Intent as UiIntent
from synthetic_upload_epub import TEXT
from test_cb_fixture_position_transport import MemoryBackend
import verify_cb_fixture_native_time_cleanup as task


class Cleanup(unittest.TestCase):
    def test_preview_apply_uncertain_and_claimed(self):
        for apply,ack,claimed in ((False,True,False),(True,True,False),(True,False,False),(True,True,True)):
            with self.subTest(apply=apply,ack=ack,claimed=claimed):self.run_case(apply,ack,claimed)
    def run_case(self,apply,ack,claimed):
        owner='900000';target='CB_Synthetic';attempt='a'*32;grant={'vid':owner};saved={'vid':owner,'cookies':{'wr_vid':owner,'wr_skey':'synthetic'}}
        seed=SeedIntent(backend=MemoryBackend());seed.reserve(owner,target,attempt)
        ui=UiIntent(backend=MemoryBackend());record=ui.reserve(owner,target,attempt,'b'*64)
        if claimed:ui.claim(record,'first_enter')
        effects={'cleanup':0}
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
            def __init__(self):self.authenticated=False;self.samples=[]
            def set_cookie(self,*_args):pass
            def verify_account(self):self.authenticated=True
            def inspect(self,_book):
                return dict(book_id=target,chapter_uid='9',source_format='web_xhtml',source='<p>'+TEXT+'</p>',
                    source_raw_sha256=hashlib.sha256(TEXT.encode()).hexdigest(),chapters=[dict(chapterUid='9',chapterIdx=1)],context={'progress':{}})
            def close(self):pass
        class NativeRead:
            def __init__(self,_grant,_target):pass
            def progress(self):return {}
        journal=Journal()
        with patch.object(task,'CbReadingProbe',Web),patch.object(task,'NativeRead',NativeRead),\
             patch.object(task,'position_plan',return_value={'chapter':'9','first':44}),\
             patch.object(task,'state',return_value=dict(kind='located',chapter_uid='9',chapter_offset=44,summary=LONG_SUMMARY)),\
             patch.object(task,'counters',return_value={'readingTime':0}),patch.object(task,'check'),\
             patch.object(task,'readback',return_value=ack),patch.object(task,'save_refreshed_web_session',return_value=False):
            result=task.run(saved,None,Native(),grant,journal,seed,ui,apply=apply,probe_factory=Probe)
        want='UNVERIFIED' if claimed or apply and not ack else 'FIXTURE_REMOVED' if apply else 'READ_ONLY_PREVIEW'
        self.assertEqual(result['result'],want);self.assertEqual(effects['cleanup'],int(apply and not claimed))
        self.assertEqual(journal.value['phase'],'imported' if claimed or not apply else 'restored' if ack else 'cleanup_pending')


if __name__=='__main__':unittest.main()
