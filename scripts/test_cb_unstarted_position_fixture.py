from contextlib import redirect_stdout
from copy import deepcopy
import io
import json
import time
import unittest
from unittest.mock import patch

from cb_fixture_web_time_evidence import Evidence
from cb_fixture_web_time_intent import Intent
from test_cb_fixture_position_transport import MemoryBackend
from test_cb_txt_initial_fixture_plan import txt_fixture
from test_cb_unstarted_time_fixture import Harness as TimeHarness
from txt_coordinates import PlainSource
import verify_cb_unstarted_position_fixture as task


class Harness(TimeHarness):
    def __init__(self,mode='success'):
        super().__init__();self.position_mode=mode
        book,sample=txt_fixture('😀\r\n');sample['source_raw_sha256']='b'*64
        self.target=book;self.sample=sample;self.position['bookId']=book
        self.position_intent=Intent(backend=MemoryBackend());self.position_evidence=Evidence(backend=MemoryBackend())
        self.position_sent=0
    def probe_factory(self,plan,owner,authority,intent):
        fixture=self
        class Probe:
            authenticated=False;sent=0
            def set_cookie(self,*_):pass
            def verify_account(self):self.authenticated=True
            def close(self):pass
            def bind(self,payload):self.expected=deepcopy(payload)
            def send_once(self,payload,permit,reservation):
                assert self.sent==0 and payload==self.expected and authority() and intent.verify(reservation,permit)
                self.sent=1;fixture.position_sent+=1
                fixture.position.update(chapterUid=plan['chapter'],chapterIdx=plan['index'],chapterOffset=plan['first'],
                                        progress=plan['percent'],summary=payload['sm'])
                if fixture.position_mode=='bad_count':fixture.position['readingTime']=0
                if fixture.position_mode=='lost':raise TimeoutError()
                return {} if fixture.position_mode=='no_ack' else {'succ':1}
        return Probe()
    def position_after(self,context,report):
        return task.position_trial(context,report,self.position_intent,self.position_evidence,
                                   probe_factory=self.probe_factory,sleep=self.sleep)
    def execute_both(self):
        with patch.object(task,'CbReadingProbe',side_effect=self.source_factory):
            return self.execute(after_time=self.position_after)


class PositionFixtureTest(unittest.TestCase):
    def test_synthetic_time_then_position_then_exact_cleanup(self):
        h=Harness();result=h.execute_both()
        self.assertEqual(result['result'],'UNSTARTED_TIME_FIXTURE_VERIFIED',result)
        self.assertEqual(result['position_probe']['result'],'PASS')
        self.assertEqual((h.sent,h.position_sent,result['account_data_writes_known']),(1,1,5))
        self.assertTrue(h.cleaned and result['position_probe']['counters_preserved'])
        self.assertEqual(h.execute_both()['result'],'UNVERIFIED')
        self.assertEqual((h.sent,h.position_sent),(1,1))

    def test_unknown_first_position_does_not_clean_or_replay(self):
        for mode in ('lost','no_ack','bad_count'):
            h=Harness(mode);result=h.execute_both()
            self.assertEqual(result['result'],'UNVERIFIED',result)
            self.assertTrue(result['position_write_uncertain']);self.assertFalse(h.cleaned)
            self.assertEqual((h.sent,h.position_sent),(1,1))
            self.assertEqual(h.execute_both()['result'],'UNVERIFIED');self.assertEqual(h.position_sent,1)

    def test_consumed_position_intent_prevents_any_import(self):
        h=Harness();h.position_intent.backend.save(b'used')
        # Test the actual preflight without loading credentials or entering the uploader.
        result=task.execute({},None,None,{},h.journal,h.receipt,h.intent,h.evidence,h.position_intent,h.position_evidence)
        self.assertEqual(result['result'],'UNVERIFIED');self.assertEqual(h.uploads,0)

    def test_offline_default_does_not_load_credentials(self):
        with patch.object(task,'SessionStore',side_effect=AssertionError),redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_transport_scope_is_exact_and_single_use(self):
        book,sample=txt_fixture();plan=task.position_plan(book,sample);intent=Intent(backend=MemoryBackend())
        reservation=intent.reserve('900000',book,'a'*32,'b'*64);permit=intent.claim(reservation)
        probe=task.PositionProbe(plan,'900000',lambda:True,intent);probe.set_cookie('wr_vid','900000');probe.authenticated=True
        body=task.fixture_body(plan,'enter');body['sm']=PlainSource(sample['source']).excerpt(plan['first'])['text']
        body['s']=task.weread_sign(task.sorted_query({k:v for k,v in body.items() if k!='s'}));probe.bind(body)
        with patch.object(task.WebSourceProbe,'request',return_value={'succ':1}) as request:
            changed=dict(body,sm='other')
            with self.assertRaises(ValueError):probe.send_once(changed,permit,reservation)
            self.assertEqual(probe.send_once(body,permit,reservation),{'succ':1})
            with self.assertRaises(ValueError):probe.send_once(body,permit,reservation)
            self.assertEqual(request.call_count,1)
        probe.sent=1;probe.reservation=reservation;probe.permit=permit
        with patch.object(task.time,'time',return_value=body['ct']):
            probe.guard('first_position',task.WRITE_URL,body)
            with self.assertRaises(ValueError):probe.guard('first_position','https://invalid.example/',body)
            with self.assertRaises(ValueError):probe.guard('first_position',task.WRITE_URL,dict(body,sm='tampered'))


if __name__=='__main__':unittest.main()
