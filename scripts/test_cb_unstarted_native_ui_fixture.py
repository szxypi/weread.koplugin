from contextlib import redirect_stdout
from copy import deepcopy
import io
import json
import unittest
from unittest.mock import patch

from cb_fixture_web_time_evidence import Evidence
from cb_fixture_web_time_intent import Intent
from test_cb_fixture_position_transport import MemoryBackend
from test_cb_txt_initial_fixture_plan import txt_fixture
from test_cb_unstarted_time_fixture import Harness as TimeHarness
import verify_cb_unstarted_native_ui_fixture as task


class Harness(TimeHarness):
    def __init__(self,mode='success'):
        super().__init__();self.ui_mode=mode;self.calls=[]
        book,sample=txt_fixture('😀\r\n');sample['source_raw_sha256']='b'*64
        self.target=book;self.sample=sample;self.position['bookId']=book
        self.position_intent=Intent(backend=MemoryBackend());self.position_evidence=Evidence(backend=MemoryBackend())
    def runner(self,command,payload):
        assert command==['synthetic'];self.calls.append(payload['armed'])
        if payload['armed']:
            self.position.update(chapterUid=payload['chapter'],chapterIdx=payload['chapter_idx'],chapterOffset=payload['offset'],
                                 progress=42,summary=payload['expected_summary'])
            if self.ui_mode=='wrong_count':self.position['readingTime']=0
            if self.ui_mode=='lost':raise TimeoutError()
        return True
    def ui_after(self,context,report):
        return task.ui_trial(context,report,self.grant,self.position_intent,self.position_evidence,['synthetic'],
                             runner=self.runner,attest=lambda:['synthetic'])
    def execute_ui(self):
        with patch.object(task,'CbReadingProbe',side_effect=self.source_factory):
            return self.execute(after_time=self.ui_after)


class NativeUiFixtureTest(unittest.TestCase):
    def test_full_flow_dry_then_one_ui_write_and_cleanup(self):
        h=Harness();result=h.execute_ui()
        self.assertEqual(result['result'],'UNSTARTED_TIME_FIXTURE_VERIFIED',result)
        self.assertEqual(h.calls,[False,True]);self.assertEqual(result['position_probe']['result'],'PASS')
        self.assertTrue(h.cleaned and result['position_probe']['offline_reopen'])
        self.assertEqual(result['account_data_writes_known'],5)
        self.assertEqual(h.execute_ui()['result'],'UNVERIFIED');self.assertEqual(h.calls,[False,True])

    def test_uncertain_ui_or_changed_count_retains_fixture(self):
        for mode in ('lost','wrong_count'):
            h=Harness(mode);result=h.execute_ui()
            self.assertEqual(result['result'],'UNVERIFIED',result);self.assertEqual(h.calls,[False,True])
            self.assertTrue(result['position_write_uncertain']);self.assertFalse(h.cleaned)
            self.assertEqual(h.execute_ui()['result'],'UNVERIFIED')

    def test_pending_position_record_blocks_upload(self):
        h=Harness();h.position_intent.backend.save(b'used')
        result=task.execute({},None,None,{},h.journal,h.receipt,h.intent,h.evidence,h.position_intent,h.position_evidence,['synthetic'])
        self.assertEqual(result['result'],'UNVERIFIED');self.assertEqual(h.uploads,0)

    def test_offline_default_does_not_load_credentials(self):
        with patch.object(task,'SessionStore',side_effect=AssertionError),redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')


if __name__=='__main__':unittest.main()
