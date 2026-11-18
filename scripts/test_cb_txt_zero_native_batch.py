import copy
from contextlib import redirect_stdout
import io
import json
import unittest
from unittest.mock import patch

from cb_fixture_web_time_evidence import Evidence
from cb_fixture_web_time_intent import Intent
from selection_trial_mock import credentials
from test_cb_fixture_position_transport import MemoryBackend
from test_cb_txt_manual_fixture_ui_trial import Harness as ManualHarness
from verify_readtime_upload import expected_statistics
import verify_cb_txt_zero_native_batch as task


class Harness(ManualHarness):
    def __init__(self, mode=None):
        super().__init__();self.mode=mode;self.current['updateTime']=1
        self.context['initial_observed']=self.project();self.grant=credentials();self.clock=1700007200.2
        self.stats_value=dict(baseTime=0,readTimes={},totalReadTime=0,readDays=0)
        self.intent=Intent(backend=MemoryBackend());self.evidence=Evidence(backend=MemoryBackend());self.sent=0;self.checks=0;self.stat_reads=0
        self.report=dict(position_writes_known=1,position_writes_uncertain=False)
    def stats(self):
        self.stat_reads+=1
        if self.mode=='changed_before_send' and self.stat_reads==5:self.stats_value['totalReadTime']+=1
        return copy.deepcopy(self.stats_value)
    def progress(self):return self.pair()[0]
    def capability(self,name):return {'token':'synthetic-config'} if name=='config' else {'feature':{}}
    def bind(self,value,summary):
        self.payload=copy.deepcopy(value);assert value['books'][0]['summary']==summary
    def send_once(self,value,permit):
        assert value==self.payload and permit() and self.sent==0
        self.sent=1;self.current['readingTime']=2
        self.stats_value=expected_statistics(self.stats_value,int(self.clock)-2,2,time_zone='+08:00')
        if self.mode=='lost':raise ValueError('unknown')
        return {} if self.mode=='no_ack' else {'succ':1}
    def version(self,summary):
        self.checks+=1
        summary.update(native_version_category='zero',catalog_root_version_category='absent',catalog_book_version_category='absent')
        if self.mode=='version' or self.mode=='changed_version' and self.checks>1:summary['native_version_category']='positive'
        return True
    def sleep(self,seconds):self.clock+=seconds
    def execute(self):
        with patch.object(task,'local_zone',return_value='+08:00'):
            return task.zero_trial(self.context,self.report,self.grant,self.intent,self.evidence,self,self.version,
                                   clock=lambda:self.clock,monotonic=lambda:self.clock,sleep=self.sleep,random=lambda _limit:123)


class ZeroNativeBatchTest(unittest.TestCase):
    def test_zero_wire_version_preserves_other_signed_fields(self):
        h=Harness();rows=[dict(start_time=1700007190,duration=2,time_zone='+08:00',book_version=1)]
        original=task.positive_batch(h.grant,h.context['target'],rows,'synthetic-guest','synthetic-config',1700007200,123,
                                     1700007200000,123,current_zone='+08:00',summary='synthetic summary')
        value=task.zero_batch(h.grant,h.context['target'],1700007190,1700007200,'synthetic-guest','synthetic-config',
                              'synthetic summary',123,123,'+08:00')
        self.assertEqual(value['books'][0]['bookVersion'],0)
        value['books'][0]['bookVersion']=1;self.assertEqual(value,original)

    def test_success_is_single_send_and_independent_readback(self):
        h=Harness();self.assertTrue(h.execute());self.assertEqual(h.sent,1)
        self.assertEqual(h.payload['books'][0]['bookVersion'],0)
        self.assertTrue(h.report['zero_version_native_batch_verified']);self.assertFalse(h.report['native_time_write_uncertain'])
        self.assertEqual(h.report['book_seconds_delta'],2);self.assertEqual(h.report['statistics_seconds_delta'],2)
        with self.assertRaises(Exception):h.execute()
        self.assertEqual(h.sent,1)

    def test_missing_ack_and_lost_reply_never_replay(self):
        for mode in ('no_ack','lost'):
            h=Harness(mode)
            if mode=='lost':
                with self.assertRaises(ValueError):h.execute()
            else:self.assertFalse(h.execute())
            self.assertEqual(h.sent,1);self.assertTrue(h.report['native_time_write_uncertain'])
            with self.assertRaises(Exception):h.execute()
            self.assertEqual(h.sent,1)

    def test_changed_version_or_shelf_blocks_send(self):
        for mode in ('version','changed_version'):
            h=Harness(mode);self.assertFalse(h.execute());self.assertEqual(h.sent,0)
        h=Harness();h.context['shelf_current']=lambda:False
        self.assertFalse(h.execute());self.assertEqual(h.sent,0)
        h=Harness('changed_before_send');self.assertFalse(h.execute());self.assertEqual(h.sent,0)
        self.assertIsNotNone(h.intent.backend.load())

    def test_offline_entry_does_not_open_credentials(self):
        with patch.object(task,'SessionStore') as session,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]),0)
        session.assert_not_called();self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def test_native_probe_is_one_shot_and_bound_to_exact_request(self):
        h=Harness();h.execute();payload=h.payload;summary=payload['books'][0]['summary']
        with patch.object(task.NativeProbe,'request',return_value={'succ':1}) as request, patch.object(task.time,'time',return_value=h.clock):
            probe=task.ZeroBatchProbe(h.grant,h.context['target'],lambda:True)
            self.assertEqual(probe.capability('config'),{'succ':1})
            with self.assertRaises(ValueError):probe.capability('config')
            with self.assertRaises(ValueError):probe.capability('other')
            probe.bind(payload,summary)
            changed=copy.deepcopy(payload);changed['books'][0]['bookVersion']=1
            with self.assertRaises(ValueError):probe.send_once(changed,lambda:True)
            with self.assertRaises(ValueError):probe.send_once(payload,lambda:False)
            self.assertEqual(probe.sent,0)
            self.assertEqual(probe.send_once(payload,lambda:True),{'succ':1})
            self.assertEqual(probe.sent,1)
            with self.assertRaises(ValueError):probe.send_once(payload,lambda:True)
            self.assertEqual(request.call_count,2)
            self.assertEqual(request.call_args.kwargs['body'],payload)

    def test_native_probe_timeout_marks_the_single_send_consumed(self):
        h=Harness();h.execute();payload=h.payload;summary=payload['books'][0]['summary']
        probe=task.ZeroBatchProbe(h.grant,h.context['target'],lambda:True);probe.bind(payload,summary)
        with patch.object(task.NativeProbe,'request',side_effect=TimeoutError), patch.object(task.time,'time',return_value=h.clock):
            with self.assertRaises(TimeoutError):probe.send_once(payload,lambda:True)
            self.assertEqual(probe.sent,1)
            with self.assertRaises(ValueError):probe.send_once(payload,lambda:True)


if __name__=='__main__':unittest.main()
