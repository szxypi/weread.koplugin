"""Scoped pipe broker/state boundaries; no actual account or native network."""
from copy import deepcopy
import io
import time
from unittest.mock import Mock,patch
from contextlib import redirect_stdout
import unittest
from secure_native_txt_roundtrip import NativeTxtRoundtripStore
from test_secure_native_session import Backend
from native_txt_read_model import body
from native_position_flow_contract import validate_payload,validate_stage,FLAGS
import verify_native_position_flow as task


def result(armed=True):
    stage=dict(result='PASS',phase='complete',permit_writes=armed,mock=True,native_gets=16 if armed else 4,native_posts=2 if armed else 0,
        denied=0,screenshots=0,failed_line=0,completed_steps=2 if armed else 0,blocked_writes=0 if armed else 1,**{k:True for k in FLAGS})
    return dict(result='PASS',profile_removed=True,installed={'files':275,'bytes_match':True},stage=stage)


def sequence(payload):
    events=[]
    for seq in (1,2) if payload['permit_writes'] else (1,):
        p=payload['plan']['target' if seq==1 else 'baseline']
        b=body(payload['credentials'],p,payload['plan']['version'],payload['guest'],int(time.time()),123,payload['time_zone'])
        events.append(('STEP',dict(kind='claim' if payload['permit_writes'] else 'dry_body',seq=seq,body=b)))
        if payload['permit_writes']:
            events.extend([('STEP',dict(kind='ack',seq=seq)),('STEP',dict(kind='verified',seq=seq))])
    events.append(('RESULT',result(payload['permit_writes'])));return events


class Child:
    def __init__(self):self.stdin=io.BytesIO();self.stdout=io.BytesIO();self.code=None
    def poll(self):return self.code
    def wait(self,timeout=None):self.code=0;return 0


class FlowTests(unittest.TestCase):
    def run_case(self,events=None,armed=True,after=None):
        payload=task.mock_payload(armed);store=NativeTxtRoundtripStore(Backend(),native=True);report={};child=Child();events=events or sequence(payload)
        frames=Mock();frames.next.side_effect=events
        replies=[]
        def answer(stream,value):
            if value['ok']:
                state,_r=store.read()
                if armed and value['kind']=='claim':self.assertEqual(state['phase'],'advance_pending' if value['seq']==1 else 'restore_pending')
                if armed and value['kind']=='ack':self.assertEqual(state['phase'],'advance_acknowledged' if value['seq']==1 else 'restore_acknowledged')
            replies.append(value)
        with patch.object(task.subprocess,'Popen',return_value=child),patch.object(task,'Frames',return_value=frames),patch.object(task,'reply',side_effect=answer),patch.object(task,'stop') as stop:
            try:task.execute(payload,['synthetic-native-runner'],store,report,after=after)
            except Exception:report['stopped']=True
        stop.assert_called_once_with(child);return store,report,replies
    def test_two_claims_acks_and_verified_reads_are_monotonic_and_retired(self):
        store,r,replies=self.run_case()
        self.assertEqual(store.read()[0]['phase'],'retired');self.assertEqual(len(replies),6)
        self.assertEqual(r['synthetic_posts'],2);self.assertEqual(r['account_data_posts'],0);self.assertFalse(r['actual_native_write_flow_verified'])
    def test_disarmed_body_check_never_reserves_a_write(self):
        store,r,replies=self.run_case(armed=False)
        self.assertEqual(store.read(),(None,None));self.assertEqual(len(replies),1);self.assertEqual(r['account_data_posts'],0)
    def test_ack_is_saved_even_when_following_independent_read_fails(self):
        store,r,_replies=self.run_case(after=Mock(side_effect=ValueError('native_txt/position')))
        self.assertTrue(r['stopped']);self.assertEqual(store.read()[0]['phase'],'advance_acknowledged')
        self.assertEqual(r['explicit_success_receipts'],1)
    def test_unknown_body_signature_coordinate_or_hours_never_claims(self):
        for change in ({'signature':'0'*64},{'chapterOffset':999},{'hours':{}},{'readingTime':True}):
            payload=task.mock_payload(True);events=sequence(payload);events[0][1]['body'].update(change)
            store,r,_replies=self.run_case(events)
            self.assertTrue(r['stopped']);self.assertEqual(store.read(),(None,None))
    def test_stale_clock_or_boolean_random_is_not_approved(self):
        for change in ({'timestamp':int(time.time())-31},{'random':True}):
            events=sequence(task.mock_payload(True));events[0][1]['body'].update(change)
            store,r,_replies=self.run_case(events);self.assertTrue(r['stopped']);self.assertEqual(store.read(),(None,None))
    def test_duplicate_claim_cannot_consume_another_slot(self):
        events=sequence(task.mock_payload(True));events.insert(1,deepcopy(events[0]))
        store,r,_replies=self.run_case(events);self.assertTrue(r['stopped']);self.assertEqual(store.read()[0]['posts'],1)
    def test_verified_frame_without_a_saved_ack_cannot_advance(self):
        events=sequence(task.mock_payload(True));events.pop(1)
        store,r,_replies=self.run_case(events);self.assertTrue(r['stopped']);self.assertEqual(store.read()[0]['phase'],'advance_pending')
    def test_missing_profile_cleanup_is_not_passed(self):
        events=sequence(task.mock_payload(True));events[-1][1]['profile_removed']=False
        _store,r,_replies=self.run_case(events);self.assertTrue(r['stopped']);self.assertEqual(r['result'],'UNVERIFIED')
    def test_native_protocol_cannot_load_or_overwrite_python_trial(self):
        backend=Backend();store=NativeTxtRoundtripStore(backend,native=True);store.reserve(task.mock_payload(True)['plan'])
        with self.assertRaises(Exception):NativeTxtRoundtripStore(backend).read()
        self.assertNotEqual(store.service,NativeTxtRoundtripStore(Backend()).service)
    def test_real_grant_cannot_be_marked_mock_or_input_unbound(self):
        for mutate in (lambda v:v['credentials'].update(accessToken='synthetic-other-token'),lambda v:v['plan'].update(owner_sha256='f'*64),
                       lambda v:v.update(permit_writes=1),lambda v:v.update(shelf_books=True)):
            value=task.mock_payload(True);mutate(value)
            with self.assertRaises(ValueError):validate_payload(value,True)
    def test_incomplete_stage_or_wrong_mode_is_rejected(self):
        for change in ({'native_posts':1},{'mock':0},{'denied':1},{'heartbeat':False},{'blocked_writes':1}):
            stage=result()['stage'];stage.update(change)
            with self.assertRaises(ValueError):validate_stage(stage,True)
    def test_default_never_loads_saved_session_or_launches_native(self):
        with patch.object(task,'SessionStore') as saved,patch.object(task.subprocess,'Popen') as child,redirect_stdout(io.StringIO()) as out:self.assertEqual(task.main([]),0)
        saved.assert_not_called();child.assert_not_called();self.assertIn('OFFLINE_ONLY',out.getvalue())


if __name__=='__main__':unittest.main()
