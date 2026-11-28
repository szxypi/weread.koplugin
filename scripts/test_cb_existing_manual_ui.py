"""Offline safety and recovery tests for one existing-book UI round trip."""
from contextlib import redirect_stdout
import copy
import hashlib
import io
import json
import unittest
from unittest.mock import patch

from cb_cloud_position import observed
from cb_existing_position_intent import Intent as UiIntent
from cb_manual_restore_intent import Intent as RestoreIntent
from secure_weread_session import StoreError
from test_cb_fixture_position_transport import MemoryBackend
from test_cb_full_summary_payload import sample as original_sample
import verify_cb_existing_manual_ui as task


class TestExistingManualUi(unittest.TestCase):
    def test_offline_never_accesses_session(self):
        with patch.object(task,'SessionStore') as store,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        store.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_single_restore_slot_never_replays(self):
        backend=MemoryBackend();intent=RestoreIntent(backend=backend)
        record=intent.reserve('900000','CB_Synthetic','a'*32,'b'*64)
        receipt=intent.claim(record);self.assertTrue(intent.verify(record,receipt))
        self.assertFalse(intent.verify(record,b'forged'))
        with self.assertRaises(StoreError):intent.claim(record)
        with self.assertRaises(StoreError):intent.reserve('900000','CB_Synthetic','b'*32,'b'*64)

    def test_only_selected_position_summary_and_integer_percent_may_change(self):
        plan,raw=original_sample();chapters=[dict(chapterUid=2,chapterIdx=2)]
        base=observed(raw,plan['book_id'],chapters,'web');actual=copy.deepcopy(base)
        for key in ('state','projection'):actual[key].update(chapter_offset=plan['target']['chapter_offset'],summary='new',raw_percent=26)
        self.assertTrue(task.expected_step(base,actual,plan['target']['chapter_offset'],'new'))
        for key,value in (('chapter_idx',3),('chapter_uid','3'),('raw_percent',26.5),('raw_percent',float('nan'))):
            wrong=copy.deepcopy(actual);wrong['state'][key]=value
            self.assertFalse(task.expected_step(base,wrong,plan['target']['chapter_offset'],'new'))
        wrong=copy.deepcopy(actual);wrong['counters']['readingTime']['present']=True
        self.assertFalse(task.expected_step(base,wrong,plan['target']['chapter_offset'],'new'))

    def test_success_restores_full_baseline_and_unknown_ui_never_replays(self):
        for success in (True,False):
            with self.subTest(success=success):self.run_trial(success)

    def run_trial(self,success):
        plan,raw=original_sample();book=plan['book_id'];source='<html><body><p>Unique synthetic position with sufficiently long nearby context.</p></body></html>'
        chapters=[dict(chapterUid=2,chapterIdx=2,wordCount=1000,title='Synthetic')]
        sample=dict(book_id=book,chapter_uid='2',source_format='web_xhtml',source=source,source_raw_sha256=hashlib.sha256(source.encode()).hexdigest(),
                    chapters=chapters,context=plan['context'])
        cloud=copy.deepcopy(raw['book']);original=copy.deepcopy(cloud)
        saved=dict(vid='900000',cookies={'wr_vid':'900000','wr_skey':'synthetic-session'})
        class Store:
            def load(self):return copy.deepcopy(saved)
        class Base:
            def __init__(self):self.authenticated=False;self.samples=[];self.progress={}
            def set_cookie(self,*_args):pass
            def verify_account(self):self.authenticated=True
            def close(self):pass
            def request(self,stage,_url,*_args):
                if stage=='shelf':return dict(books=[dict(bookId=book)])
                return dict(book=copy.deepcopy(cloud))
        class FakeWeb(Base):
            def inspect(self,identity):
                assert identity==book
                self.progress[(identity,'progress_before')]=dict(book=copy.deepcopy(cloud))
                return copy.deepcopy(sample)
        ui=UiIntent(backend=MemoryBackend());restore=RestoreIntent(backend=MemoryBackend());calls=[];native_calls=[]
        def fake_ui(_runner,payload,width,height,dpi):
            calls.append((width,height,dpi))
            if not success and len(calls)==2:raise ValueError('unknown UI effect')
            cloud.update(chapterOffset=payload['next_offset'],summary=payload['expected_summary'],progress=26)
            return True
        def fake_native(_command,position,_context,_cookies,mode):
            native_calls.append(mode)
            cloud.update(chapterOffset=position['chapter_offset'],summary=position['summary'],progress=position['percent'])
            return dict(accepted=True)
        args=['--saved-session','--apply','--lua-command-json','["lua"]','--runner','runner']
        with patch.object(task,'SessionStore',Store),patch.object(task,'Web',FakeWeb),patch.object(task,'WebSourceProbe',Base),\
             patch.object(task,'ui_store',return_value=ui),patch.object(task,'RestoreIntent',return_value=restore),\
             patch.object(task,'ui_runner',side_effect=fake_ui),patch.object(task,'native',side_effect=fake_native),\
             patch.object(task,'compare',return_value=True),patch.object(task,'save_refreshed_web_session',return_value=False),redirect_stdout(io.StringIO()) as output:
            result=task.main(args)
        report=json.loads(output.getvalue())
        self.assertEqual(result,0 if success else 1)
        self.assertEqual(report['position_restored'],success)
        self.assertEqual(report['ui_writes_allocated'],4)
        self.assertEqual(report['restore_writes_allocated'],1 if success else 0)
        self.assertEqual(len(native_calls),1 if success else 0)
        self.assertEqual(cloud==original,success)
        self.assertNotIn(book,output.getvalue());self.assertNotIn('synthetic-session',output.getvalue())
        self.assertNotIn(original['summary'],output.getvalue())
        with self.assertRaises(StoreError):ui.reserve('900000',book,'a'*32,'b'*64)
        with self.assertRaises(StoreError):restore.reserve('900000',book,'a'*32,'b'*64)


if __name__=='__main__':unittest.main()
