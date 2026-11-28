"""Synthetic first-position trial: ownership, counters, receipts and replay."""
from copy import deepcopy
from contextlib import redirect_stdout
import hashlib
import io
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from native_direct_time_trial_store import Intent
from native_time_capture_evidence import account_key
from test_cb_fixture_position_transport import MemoryBackend
import verify_ordinary_unstarted_initial as task
import inspect_ordinary_unstarted_initial as inspect_task


class InitialTrialTests(unittest.TestCase):
    def test_independent_inspection_is_offline_by_default(self):
        with patch.object(inspect_task,'SessionStore',side_effect=AssertionError('unexpected session access')),redirect_stdout(io.StringIO()):
            self.assertEqual(inspect_task.main([]),0)

    def exercise(self,mode):
        grant=dict(vid='900000',deviceId='eink334691225'+'1'*19,
            accessToken='synthetic-access',refreshToken='synthetic-refresh')
        saved=dict(vid=grant['vid'],cookies={'wr_vid':grant['vid'],'wr_skey':'synthetic-cookie'})
        raw_source=b'Synthetic source';digest=hashlib.sha256(raw_source).hexdigest()
        prior=dict(phase='verified',attempt='1'*32,plan=dict(selection=dict(start_time=1699999990,duration=2),
            record=dict(owner=account_key(grant['vid']),source=dict(book_id='42',chapter_uid='7',version=7,source_sha256=digest)),
            body=dict(books=[dict(bookId='42',readingTime=2)])))
        if mode=='foreign':prior['plan']['record']['owner']='f'*20
        target=dict(book_id='42',chapter_uid='7',chapter_idx=1,chapter_offset=35,raw_percent=0,summary='Synthetic summary')
        model=dict(sent=0,clock=1700007200,reads=0)
        def point():
            value=dict(bookId='42',chapterUid=7 if model['sent'] else 0,chapterOffset=35 if model['sent'] else 0,progress=0,
                readingTime=3 if mode=='counts_changed' and model['sent'] else 2,recordReadingTime=0,ttsTime=0)
            if model['sent']:value.update(chapterIdx=1,summary='Synthetic summary')
            return value
        class Sessions:
            def load(self):return deepcopy(saved)
        class Natives:
            def load(self,_owner):return deepcopy(grant)
        class Prior:
            def read(self):return deepcopy(prior),b'unchanged-prior'
        class Chapter:
            def inspect(self,*_args):
                source=b'Changed source' if mode=='changed_source' else raw_source
                return dict(book_id='42',expected=dict(format='epub',version=7)),dict(uid=7,free_or_owned=True),dict(html=True,source=source)
        class Reads:
            def __init__(self,*_args):pass
            def request(self,stage,*_args,**_kwargs):
                if stage=='shelf':return {'shelf':'synthetic'}
                if stage=='feature':return {'feature':{}}
                model['reads']+=1;return point()
        class Web:
            def __init__(self):self.vid=None;self.book_id=None;self.chapter=None
            def set_cookie(self,*_args):pass
            def verify_account(self):pass
            def request(self,stage,*_args,**_kwargs):return {'shelf':'synthetic'} if stage=='shelf' else point()
            def close(self):pass
        def post(_self,stage,url,body=None,credentials=None,timeout=15):
            self.assertEqual(stage,'unstarted_initial_write');self.assertEqual(url,task.NATIVE+'/book/read')
            self.assertEqual(body['readingTime'],0);self.assertEqual(body['hours'],[]);model['sent']+=1
            return {'succ':0} if mode=='bad_ack' else {'succ':1}
        def sleep(seconds):model['clock']+=seconds
        clock=SimpleNamespace(time=lambda:model['clock'],sleep=sleep)
        intent=Intent(backend=MemoryBackend())
        with patch.object(task,'store',return_value=intent),patch.object(task,'time_store',return_value=Prior()),\
             patch.object(task,'other_pending',return_value=False),patch.object(task,'SessionStore',Sessions),\
             patch.object(task,'NativeSessionStore',Natives),patch.object(task,'ChapterProbe',Chapter),\
             patch.object(task,'Reads',Reads),patch.object(task,'WebSourceProbe',Web),\
             patch.object(task,'chapter_index',return_value=1),patch.object(task,'catalog',return_value='catalog'),\
             patch.object(task,'current_source',return_value=raw_source),patch.object(task,'select_target',return_value=deepcopy(target)),\
             patch.object(task,'state_hash',return_value='shelf-hash'),patch.object(task,'web_cookies',return_value=saved['cookies']),\
             patch.object(task,'local_zone',return_value='+08:00'),patch.object(task,'time',clock),\
             patch.object(task.NativeProbe,'request',post):
            report=task.run(apply=mode!='dry')
        return report,intent,model

    def test_dry_run_has_no_claim_or_send(self):
        report,intent,model=self.exercise('dry')
        self.assertEqual(report['result'],'UNSTARTED_INITIAL_DRY_VERIFIED');self.assertEqual(model['sent'],0)
        self.assertEqual(intent.read(),(None,None))

    def test_one_verified_zero_time_position_preserves_time(self):
        report,intent,model=self.exercise('success')
        self.assertEqual(report['result'],'UNSTARTED_INITIAL_POSITION_VERIFIED');self.assertEqual(model['sent'],1)
        self.assertEqual(report['independent_readbacks'],2);self.assertEqual(report['reading_time_preserved'],2)
        self.assertFalse(report['original_no_chapter_restored']);self.assertEqual(intent.read()[0]['phase'],'verified')
        with self.assertRaises(Exception):intent.claim({'selection':{},'record':{},'body':{},'baseline':{}})

    def test_bad_receipt_or_changed_counts_never_retry(self):
        for mode,phase in (('bad_ack','claimed'),('counts_changed','acknowledged')):
            with self.subTest(mode=mode):
                report,intent,model=self.exercise(mode)
                self.assertEqual(report['result'],'UNVERIFIED');self.assertEqual(model['sent'],1)
                self.assertEqual(intent.read()[0]['phase'],phase)

    def test_foreign_account_and_changed_source_are_blocked(self):
        for mode in ('foreign','changed_source'):
            with self.subTest(mode=mode):
                report,intent,model=self.exercise(mode)
                self.assertEqual(report['result'],'UNVERIFIED');self.assertEqual(model['sent'],0)
                self.assertEqual(intent.read(),(None,None))


if __name__=='__main__':unittest.main()
