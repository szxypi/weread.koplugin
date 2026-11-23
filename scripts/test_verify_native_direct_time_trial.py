"""Offline supervision, one-shot persistence and readback tests."""
from copy import deepcopy
import hashlib
import io
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from native_direct_time_trial_store import Intent
from test_cb_fixture_position_transport import MemoryBackend
from test_native_direct_time_trial_contract import fixture
from verify_readtime_upload import expected_statistics
import verify_native_direct_time_trial as task


class DirectTimeSupervisorTests(unittest.TestCase):
    def exercise(self,mode,predecessor=None,automatic=False):
        now,grant,expected,selection,reference,baseline,event=fixture()
        raw=b'Synthetic direct book content';source_hash=hashlib.sha256(raw).hexdigest()
        reference['source_sha256']=source_hash;event['record']['metadata']['source']['source_sha256']=source_hash
        event['record']['metadata']['source']['ref']['source_sha256']=source_hash
        expected['source_sha256']=source_hash
        saved=dict(vid=grant['vid'],cookies={'wr_vid':grant['vid'],'wr_skey':'private-web-cookie'})
        class FakeSession:
            def load(self):return deepcopy(saved)
        class FakeNativeSession:
            def load(self,_owner):return deepcopy(grant)
        class FakeWeb:
            def __init__(self):self.cookies=[SimpleNamespace(name='wr_vid',value=grant['vid']),
                SimpleNamespace(name='wr_skey',value='private-web-cookie')]
            def set_cookie(self,*_args):pass
            def verify_account(self):pass
            def close(self):pass
        class FakeProbe:
            def inspect(self,_grant,_offset):return (dict(book_id='42',expected=dict(format='epub',version=7)),
                dict(uid=7),dict(html=True,source=raw))
        class FakeNative:
            def __init__(self,*_args):pass
            def request(self,stage,*_args,**_kwargs):
                return {'token':'synthetic-config'} if stage=='time_config' else {'feature':{'guest_token':'synthetic-guest'}}
        initial={key:deepcopy(baseline[key]) for key in ('native_point','web_point','counts','shelf_hash','months')}
        after=deepcopy(initial);after['counts']['readingTime']+=6
        month=next(iter(after['months']))
        after['months'][month]=expected_statistics(initial['months'][month],selection['protocol_rows'][0]['start_time'],6)
        responses=[deepcopy(initial),deepcopy(initial),deepcopy(initial),deepcopy(after),deepcopy(after)]
        if mode=='changed':responses[2]['counts']['readingTime']+=1
        class FakeChild:
            def __init__(self):self.stdin=io.BytesIO();self.stdout=io.BytesIO();self.returncode=None
            def wait(self,timeout=None):self.returncode=0;return self.returncode
            def poll(self):return self.returncode
        child=FakeChild();events=[('STEP',dict(kind='ready',seconds=6)),('STEP',dict(kind='selection',selection=selection,reference=reference)),
            ('STEP',event)]
        armed=mode!='dry'
        if armed:events.append(('STEP',dict(kind='ack',status=200,response={'succ':0 if mode=='bad_ack' else 1})))
        events.append(('RESULT',dict(result='ACKNOWLEDGED' if armed else 'DRY_BLOCKED',profile_removed=True,stage='audit')))
        class FakeFrames:
            def __init__(self,*_args,**_kwargs):self.items=iter(events)
            def next(self):return next(self.items)
        backend=MemoryBackend();intent=Intent(backend=backend);answers=[]
        with patch.object(task,'Intent',return_value=intent),patch.object(task,'other_pending',return_value=False),\
             patch.object(task,'SessionStore',FakeSession),patch.object(task,'NativeSessionStore',FakeNativeSession),\
             patch.object(task,'ChapterProbe',FakeProbe),patch.object(task,'WebSourceProbe',FakeWeb),\
             patch.object(task,'Native',FakeNative),patch.object(task,'snapshot',side_effect=responses),\
             patch.object(task,'trusted_command',return_value=['synthetic']),patch.object(task.subprocess,'Popen',return_value=child),\
             patch.object(task,'Frames',FakeFrames),patch.object(task,'write_initial') as initial_writer,\
             patch.object(task,'reply',side_effect=lambda _stream,value:answers.append(value)),patch.object(task,'stop'),\
             patch.object(task,'time',SimpleNamespace(time=lambda:now,sleep=lambda _n:None)):
            report=task.run(apply=armed,predecessor=predecessor,automatic=automatic)
            self.assertEqual(initial_writer.call_args.args[1].get('automatic',False),automatic)
        self.assertNotIn('private-web-cookie',str(report));self.assertNotIn('synthetic-access',str(report))
        return report,intent,answers

    def test_dry_run_denies_dispatch_and_leaves_no_intent(self):
        report,intent,answers=self.exercise('dry')
        self.assertEqual(report['result'],'DIRECT_NATIVE_TIME_DRY_VERIFIED')
        self.assertEqual(intent.read(),(None,None));self.assertFalse(answers[-1]['ok'])

    def test_confirmed_send_requires_two_independent_readbacks(self):
        report,intent,answers=self.exercise('success')
        self.assertEqual(report['result'],'DIRECT_NATIVE_TIME_ACCOUNTING_VERIFIED')
        self.assertEqual(report['account_data_posts'],1);self.assertEqual(intent.read()[0]['phase'],'verified')
        self.assertEqual(len(answers),4);self.assertTrue(all(item['ok'] for item in answers))

    def test_uncertain_receipt_keeps_claim_and_cannot_retry(self):
        report,intent,answers=self.exercise('bad_ack')
        self.assertEqual(report['result'],'UNVERIFIED');self.assertIsNone(report['account_data_posts'])
        self.assertTrue(report['dispatch_may_have_occurred']);self.assertEqual(intent.read()[0]['phase'],'claimed')
        self.assertFalse(answers[-1]['ok'])

    def test_changed_baseline_rejects_before_claim(self):
        report,intent,answers=self.exercise('changed')
        self.assertEqual(report['result'],'UNVERIFIED');self.assertEqual(intent.read(),(None,None))
        self.assertEqual(report['account_data_posts'],0);self.assertFalse(answers[-1]['ok'])

    def test_predecessor_is_checked_again_before_dispatch(self):
        class Guard:
            def __init__(self):self.calls=[]
            def check(self,grant,selection=None,record=None):
                self.calls.append((selection is not None,record is not None))
                if record is not None:raise ValueError('direct_time/prior')
        guard=Guard();report,intent,answers=self.exercise('success',guard)
        self.assertEqual(guard.calls,[(False,False),(True,False),(True,True)])
        self.assertEqual(report['account_data_posts'],0);self.assertEqual(intent.read(),(None,None))
        self.assertFalse(answers[-1]['ok'])

    def test_automatic_uses_same_single_use_and_readback_rules(self):
        report,intent,_=self.exercise('success',automatic=True)
        self.assertEqual(report['result'],'DIRECT_NATIVE_TIME_ACCOUNTING_VERIFIED')
        self.assertTrue(report['automatic_shortened_interval'])
        self.assertEqual(intent.read()[0]['phase'],'verified')
        report,intent,_=self.exercise('bad_ack',automatic=True)
        self.assertEqual(report['result'],'UNVERIFIED');self.assertEqual(intent.read()[0]['phase'],'claimed')

    def test_only_bounded_new_zero_days_can_be_ignored(self):
        _now,_grant,_expected,selection,_reference,baseline,_event=fixture()
        before={key:deepcopy(baseline[key]) for key in ('native_point','web_point','counts','shelf_hash','months')}
        after=deepcopy(before);after['counts']['readingTime']+=6
        month=next(iter(after['months']));start=selection['protocol_rows'][0]['start_time']
        after['months'][month]=expected_statistics(before['months'][month],start,6)
        used=after['months'][month]['readTimes']
        keys=[str(int(month)+i*86400) for i in range(28) if str(int(month)+i*86400) not in used][:3]
        self.assertEqual(len(keys),3)
        used[keys[0]]=0
        self.assertFalse(task.matching_target(before,after,6,start))
        self.assertTrue(task.matching_target(before,after,6,start,allow_added_zero=True))
        used[keys[1]]=0;self.assertTrue(task.matching_target(before,after,6,start,allow_added_zero=True))
        used[keys[2]]=0;self.assertFalse(task.matching_target(before,after,6,start,allow_added_zero=True))
        del used[keys[2]];used[keys[1]]=1
        self.assertFalse(task.matching_target(before,after,6,start,allow_added_zero=True))


if __name__=='__main__':unittest.main()
