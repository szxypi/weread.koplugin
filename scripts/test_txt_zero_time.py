"""One actual-stage candidate, fresh configuration, no enter or retries."""
from contextlib import redirect_stdout
from copy import deepcopy
import io
import json
import unittest
from unittest.mock import Mock,patch
from test_secure_native_session import Backend
from test_txt_full_summary import Fake,bound
from txt_full_summary import payload
from secure_txt_full_summary import TxtFullSummaryStore,StoreError
from secure_txt_zero_time import TxtZeroTimeStore
from web_reader_config import token
import verify_txt_zero_time as task


class FakeZero(task.Probe,Fake):
    def request(self,stage,url,body=None,**options):
        if stage=='web_config':
            self.guard(stage,url,body)
            return dict(token='synthetic-current-config-token')
        return Fake.request(self,stage,url,body,**options)


class TxtZeroTests(unittest.TestCase):
    def execute(self,web,apply=True):
        session=Mock();saved=dict(vid='900000',cookies={});session.load.side_effect=lambda:deepcopy(saved)
        store=TxtZeroTimeStore(Backend());report={}
        with patch.object(task,'save_refreshed_web_session',return_value=False):
            try:task.run(web,session,saved,store,report,apply)
            except Exception:report['stopped']=True
        return store,report
    def test_config_rejects_absent_malformed_or_control_tokens(self):
        for value in ({},{'token':''},{'token':None},{'token':'bad\nheader'},{'token':'x'*4097}):
            with self.assertRaises(ValueError):token(value)
        self.assertEqual(token(dict(token='synthetic-token')),'synthetic-token')
    def test_single_rt_zero_full_summary_uses_current_token(self):
        web=FakeZero();store,report=self.execute(web)
        self.assertEqual(report['result'],'TXT_FULL_SUMMARY_ZERO_TIME_SAME_POINT_VERIFIED')
        self.assertEqual((web.posts,len(web.sent)),(1,1));self.assertEqual(web.sent[0]['rt'],0)
        self.assertEqual(len(web.sent[0]['sm']),30);self.assertEqual(web.wire['context']['token'],'synthetic-current-config-token')
        self.assertTrue(report['acknowledged']);self.assertEqual(store.read()[0]['posts'],1);self.assertFalse(store.pending())
    def test_preflight_performs_no_dispatch_or_reservation(self):
        web=FakeZero();store,report=self.execute(web,False)
        self.assertEqual(report['result'],'TXT_ZERO_TIME_PLAN_VERIFIED');self.assertEqual(web.posts,0);self.assertEqual(store.read(),(None,None))
    def test_enter_is_always_rejected_even_with_a_valid_payload(self):
        web=FakeZero();self.execute(web,False);claim=Mock()
        with self.assertRaises(ValueError):web.send('write_enter',payload(web.wire,'write_enter'),claim)
        claim.assert_not_called();self.assertEqual(web.posts,0)
    def test_unknown_ack_is_one_claim_and_independent_read_then_stop(self):
        web=FakeZero([{}]);store,report=self.execute(web)
        self.assertTrue(report['stopped']);self.assertTrue(report['original_readback']);self.assertEqual(web.posts,1)
        self.assertTrue(store.pending());self.assertEqual(store.read()[0]['phase'],'same_pending')
    def test_lost_response_is_not_retried(self):
        web=FakeZero([ValueError('synthetic timeout')]);store,report=self.execute(web)
        self.assertTrue(report['stopped']);self.assertTrue(report['original_readback']);self.assertEqual(web.posts,1);self.assertTrue(store.pending())
    def test_second_send_and_nonzero_time_are_rejected_before_claim(self):
        web=FakeZero();self.execute(web);claim=Mock()
        with self.assertRaises(ValueError):web.send('write_same',payload(web.wire,'write_same'),claim)
        claim.assert_not_called()
        web=FakeZero();self.execute(web,False);value=payload(web.wire,'write_same');value['rt']=1
        with self.assertRaises(ValueError):web.send('write_same',value,claim)
        claim.assert_not_called()
    def test_distinct_protocol_rejects_old_enter_intent_and_retains_tombstone(self):
        backend=Backend();old=TxtFullSummaryStore(backend);old.reserve(bound())
        with self.assertRaises(StoreError):TxtZeroTimeStore(backend).read()
        backend=Backend();store=TxtZeroTimeStore(backend);value=dict(bound(),protocol=store.protocol);r=store.reserve(value)
        r=store.advance(r,'prepared','same_pending');store.advance(r,'same_pending','retired')
        self.assertEqual(store.read()[0]['posts'],1)
        with self.assertRaises(StoreError):store.reserve(value)
    def test_readback_change_retains_pending_and_cannot_confirm(self):
        web=FakeZero();web.break_read=3;store,report=self.execute(web)
        self.assertTrue(report['stopped']);self.assertEqual(web.posts,1);self.assertTrue(store.pending())
    def test_resolution_binding_ignores_only_server_update_timestamp(self):
        first=dict(book_id='41',chapter_uid='2',chapter_idx=3,chapter_offset=12,raw_percent=3.25,summary='synthetic',updated_at=100)
        self.assertEqual(task.baseline_digest(first),task.baseline_digest(dict(first,updated_at=101)))
        for field,value in (('summary','changed'),('chapter_offset',13),('raw_percent',3.26)):
            self.assertNotEqual(task.baseline_digest(first),task.baseline_digest(dict(first,**{field:value})))

    def test_default_does_not_open_credentials(self):
        with patch.object(task,'SessionStore') as store,redirect_stdout(io.StringIO()) as out:self.assertEqual(task.main([]),0)
        store.assert_not_called();self.assertEqual(json.loads(out.getvalue())['account_data_posts'],0)


if __name__=='__main__':unittest.main()
