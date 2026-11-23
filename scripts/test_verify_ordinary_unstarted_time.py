"""Synthetic no-position time probe, including unknown outcomes and replay."""
from copy import deepcopy
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from native_direct_time_trial_store import Intent
from test_cb_fixture_position_transport import MemoryBackend
from verify_native_statistics import period
from verify_readtime_upload import expected_statistics
import verify_ordinary_unstarted_time as task


class UnstartedTimeTests(unittest.TestCase):
    def exercise(self,mode):
        grant=dict(vid='900000',deviceId='eink334691225'+'1'*19,
            accessToken='synthetic-access',refreshToken='synthetic-refresh')
        saved=dict(vid=grant['vid'],cookies={'wr_vid':grant['vid'],'wr_skey':'synthetic-cookie'})
        state=dict(wall=1700007200.2,mono=1000.0,sent=0,candidates=0)
        def sleep(seconds):state['wall']+=seconds;state['mono']+=seconds
        clock=SimpleNamespace(time=lambda:state['wall'],monotonic=lambda:state['mono'],sleep=sleep)
        month=period('monthly',int(state['wall']))[0]
        initial=dict(baseTime=month,readTimes={},totalReadTime=0,readDays=0)
        def raw():
            value=2 if state['sent'] else 0
            return dict(bookId='42',chapterUid=0,chapterOffset=0,progress=0,
                readingTime=value,recordReadingTime=0,ttsTime=0)
        class Sessions:
            def load(self):return deepcopy(saved)
        class Natives:
            def load(self,_owner):return deepcopy(grant)
        class Prior:
            def __init__(self,_store):pass
            def check(self,*_args):return True
        class Chapter:
            def inspect(self,_grant,_offset):
                state['candidates']+=1
                version=8 if mode=='source_change' and state['candidates']>1 else 7
                return (dict(book_id='42',expected=dict(format='epub',version=version)),
                    dict(uid=7,free_or_owned=True),dict(html=True,source=b'Synthetic chapter'))
            def request(self,*_args,**_kwargs):return {'shelf':'synthetic'}
        class Read:
            def __init__(self,*_args):pass
            def progress(self):return raw()
            def stats(self):
                if not state['sent']:return deepcopy(initial)
                return expected_statistics(initial,state['start'],2)
        class Capability:
            def __init__(self,*_args):pass
            def request(self,stage,*_args,**_kwargs):
                return {'token':'synthetic-config'} if stage=='unstarted_config' else {'feature':{}}
        class Web:
            def __init__(self):self.book_id=None;self.vid=None
            def set_cookie(self,*_args):pass
            def verify_account(self):pass
            def request(self,stage,*_args,**_kwargs):return {'shelf':'synthetic'} if stage=='shelf' else raw()
            def close(self):pass
        def post(_self,stage,url,body=None,credentials=None,timeout=15):
            self.assertEqual(stage,'unstarted_time_write');self.assertEqual(url,task.NATIVE+'/book/batchUploadProgress')
            self.assertIsNotNone(body);state['start']=body['books'][0]['hours'][0]['startOfHour']
            # The batch uses the current hour; preserve the exact captured start
            # from the frozen plan rather than deriving it from the hour bucket.
            value,_=intent.read();state['start']=value['plan']['selection']['start_time'];state['sent']+=1
            return {'succ':0} if mode=='bad_ack' else {'succ':1}
        backend=MemoryBackend();intent=Intent(backend=backend)
        with patch.object(task,'store',return_value=intent),patch.object(task,'other_pending',return_value=False),\
             patch.object(task,'SessionStore',Sessions),patch.object(task,'NativeSessionStore',Natives),\
             patch.object(task,'PriorGuard',Prior),patch.object(task,'ChapterProbe',Chapter),\
             patch.object(task,'NativeRead',Read),patch.object(task,'Native',Capability),patch.object(task,'WebSourceProbe',Web),\
             patch.object(task,'state_hash',return_value='shelf-hash'),patch.object(task,'web_cookies',return_value=saved['cookies']),\
             patch.object(task,'local_zone',return_value='+08:00'),patch.object(task,'time',clock),\
             patch.object(task.NativeProbe,'request',post):
            report=task.run(apply=mode!='dry')
        return report,intent,state

    def test_dry_never_claims_or_sends(self):
        report,intent,state=self.exercise('dry')
        self.assertEqual(report['result'],'UNSTARTED_TIME_DRY_VERIFIED');self.assertEqual(state['sent'],0)
        self.assertEqual(intent.read(),(None,None))

    def test_confirmed_send_is_single_use_and_verified(self):
        report,intent,state=self.exercise('success')
        self.assertEqual(report['result'],'UNSTARTED_TIME_VERIFIED');self.assertEqual(state['sent'],1)
        self.assertEqual(intent.read()[0]['phase'],'verified');self.assertTrue(report['no_chapter_and_counts_verified'])
        with self.assertRaises(Exception):intent.claim({'selection':{},'record':{},'body':{},'baseline':{}})

    def test_missing_ack_does_not_replay(self):
        report,intent,state=self.exercise('bad_ack')
        self.assertEqual(report['result'],'UNVERIFIED');self.assertEqual(state['sent'],1)
        self.assertIsNone(report['account_data_posts']);self.assertEqual(intent.read()[0]['phase'],'claimed')

    def test_source_change_stops_before_any_write(self):
        report,intent,state=self.exercise('source_change')
        self.assertEqual(report['result'],'UNVERIFIED');self.assertEqual(state['sent'],0)
        self.assertEqual(intent.read(),(None,None))


if __name__=='__main__':unittest.main()
