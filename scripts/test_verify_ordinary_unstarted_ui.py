"""Offline supervision checks; no real account, container or network."""
from contextlib import ExitStack
from copy import deepcopy
import hashlib
import unittest
from unittest.mock import patch

from native_direct_time_trial_store import Intent
from native_time_capture_evidence import account_key
from test_secure_native_session import Backend,credentials
import verify_ordinary_unstarted_ui as task


class SupervisorTests(unittest.TestCase):
    def run_case(self,mode):
        grant=credentials();saved=dict(vid=grant['vid'],cookies={'wr_vid':grant['vid'],'wr_skey':'synthetic-cookie'})
        raw=b'<html><body>synthetic chapter</body></html>';source=dict(book_id='42',chapter_uid='7',version=1,source_sha256=hashlib.sha256(raw).hexdigest())
        timing=Intent(backend=Backend());position=Intent(backend=Backend());calls=dict(execute=0,after=False)
        body={'books':[dict(bookId='42',readingTime=2)]}
        plan=dict(selection=dict(duration=2),record=dict(owner=account_key(grant['vid']),source=source),body=body,baseline={})
        receipt=timing.claim(plan);receipt=timing.advance(receipt,'acknowledged');timing.advance(receipt,'verified')
        target=dict(book_id='42',chapter_uid='7',chapter_idx=1,chapter_offset=15,raw_percent=0,summary='synthetic')
        def progress():
            point=dict(bookId='42',chapterUid=7 if calls['after'] else 0,chapterIdx=1 if calls['after'] else 0,
                chapterOffset=15 if calls['after'] else 0,progress=0,summary='synthetic' if calls['after'] else '',
                readingTime=3 if mode=='count_change' else 2,recordReadingTime=0,ttsTime=0)
            return point
        class Sessions:
            def load(self):return deepcopy(saved)
        class NativeSessions:
            def load(self,_vid):return deepcopy(grant)
        class Previous:
            def __init__(self,*_args):pass
            def check(self,*_args):
                if mode=='prior_change':raise ValueError('changed')
                return True
        class Chapter:
            def inspect(self,_grant,offset):
                assert offset==2
                return dict(book_id='42',expected=dict(format='epub',version=1)),dict(uid=7,free_or_owned=True),dict(html=True,source=raw)
        class Web:
            def set_cookie(self,*_args):pass
            def verify_account(self):pass
            def request(self,stage,*_args):return {'books':[]} if stage=='shelf' else progress()
            def close(self):pass
        class Native:
            def __init__(self,*_args):pass
            def request(self,stage,*_args,**_kwargs):
                if stage=='shelf':return {'books':[]}
                if stage=='feature':return {'feature':{}}
                return progress()
        def broker(payload,cmd,intent,body,report,*,current,before,after):
            calls['execute']+=1;self.assertTrue(current());self.assertTrue(before(None));self.assertEqual(body,raw)
            if payload['armed']:
                calls['after']=True;self.assertTrue(after(dict(desired=target)))
            report['result']='INITIAL_NATIVE_UI_VERIFIED' if payload['armed'] else 'INITIAL_NATIVE_UI_DRY_VERIFIED'
        patches=[patch.object(task,'other_pending',return_value=False),patch.object(task,'OrdinaryUnstartedUiTimeStore',return_value=timing),
            patch.object(task,'OrdinaryUnstartedUiPositionStore',return_value=position),patch.object(task,'SessionStore',Sessions),
            patch.object(task,'NativeSessionStore',NativeSessions),patch.object(task,'PreviousSamples',Previous),
            patch.object(task,'old_time_store',return_value=object()),patch.object(task,'old_position_store',return_value=object()),
            patch.object(task,'inspect_book',side_effect=lambda grant,_book:Chapter().inspect(grant,2)),
            patch.object(task,'WebSourceProbe',Web),patch.object(task,'Reads',Native),
            patch.object(task,'web_cookies',return_value=saved['cookies']),patch.object(task,'chapter_index',return_value=1),
            patch.object(task,'catalog',return_value='catalog'),patch.object(task,'current_source',return_value=b'wrong' if mode=='source_change' else raw),
            patch.object(task,'state_hash',return_value='shelf'),patch.object(task,'local_zone',return_value='+08:00'),
            patch.object(task,'state',return_value=(target,{})),patch.object(task,'command',return_value=['synthetic']),
            patch.object(task,'execute',side_effect=broker),patch.object(task.time,'sleep')]
        with ExitStack() as stack:
            for item in patches:stack.enter_context(item)
            result=task.run(apply=mode=='success')
        return result,calls
    def test_read_only_preflight_and_verified_write(self):
        for mode in ('dry','success'):
            result,calls=self.run_case(mode)
            self.assertEqual(result['result'],'INITIAL_NATIVE_UI_VERIFIED' if mode=='success' else 'INITIAL_NATIVE_UI_DRY_VERIFIED')
            self.assertEqual(calls['execute'],1);self.assertEqual(calls['after'],mode=='success')
    def test_invalid_source_prior_or_counts_never_reaches_broker(self):
        for mode in ('source_change','prior_change','count_change'):
            result,calls=self.run_case(mode)
            self.assertEqual(result['result'],'UNVERIFIED');self.assertEqual(calls['execute'],0)
            self.assertEqual(result['account_data_posts'],0)


if __name__=='__main__':unittest.main()
