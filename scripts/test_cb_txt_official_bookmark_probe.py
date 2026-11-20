"""Isolation and ownership checks for the read-only official-reader probe."""
import contextlib
from copy import deepcopy
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import Mock,patch

from personal_upload_trial import hash_value
from test_secure_native_session import Backend
from verify_cb_txt_fixture import Receipt
import verify_cb_txt_official_bookmark_probe as verify


class ProbeTests(unittest.TestCase):
    def setUp(self):
        self.state=dict(phase='restored',target='CB_Synthetic42',attempt='a'*32,plan={'owner':'900000'})
        self.record=dict(schema=1,owner='900000',target=self.state['target'],attempt=self.state['attempt'],plan_sha256=hash_value(self.state['plan']))
        self.journal=SimpleNamespace(read=lambda:(deepcopy(self.state),object()))
        self.receipt=Receipt(Backend());self.receipt.backend.save(json.dumps(self.record).encode())
        self.intent=SimpleNamespace(read=lambda:(None,None))
        self.saved={'vid':'900000','cookies':{'wr_vid':'900000','wr_skey':'synthetic'}}
        self.sample=dict(chapter_uid='2',chapters=[dict(chapterUid=2)],baseline={'chapter':'0'},source_raw_sha256='a'*64)
        self.observation=dict(source_visible=True,empty_bookmark_list=True,source_posts=2,blocked_posts=1,bookmark_gets=1)

    def test_default_never_loads_credentials_or_launches_browser(self):
        with patch.object(verify,'SessionStore') as store,patch.object(verify,'observe') as browser,contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(verify.main([]),0)
        store.assert_not_called();browser.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_only_matching_restored_fixture_can_be_inspected(self):
        self.assertEqual(verify.fixture_target(self.journal,self.receipt,self.intent,'900000'),'CB_Synthetic42')
        for bad in (dict(self.record,owner='800000'),dict(self.record,target='CB_Other'),
                    dict(self.record,plan_sha256='0'*64),dict(self.record,extra='private')):
            self.receipt.backend.save(json.dumps(bad).encode())
            with self.assertRaises(ValueError):verify.fixture_target(self.journal,self.receipt,self.intent,'900000')
        self.receipt.backend.save(json.dumps(self.record).encode());self.state['phase']='imported'
        with self.assertRaises(ValueError):verify.fixture_target(self.journal,self.receipt,self.intent,'900000')

    def test_source_and_position_must_remain_identical_and_results_are_bounded(self):
        source=Mock(side_effect=[deepcopy(self.sample),deepcopy(self.sample)]);browser=Mock(return_value=deepcopy(self.observation))
        report=verify.run(self.saved,self.journal,self.receipt,self.intent,source_reader=source,browser=browser)
        self.assertEqual(report['result'],'OFFICIAL_TXT_BOOKMARK_READ_ONLY');self.assertEqual(source.call_count,2)
        self.assertFalse(report['official_saved_bookmark_display_verified']);self.assertNotIn('CB_Synthetic42',json.dumps(report))
        changed=dict(self.sample,baseline={'chapter':'2'});source=Mock(side_effect=[deepcopy(self.sample),changed])
        self.assertEqual(verify.run(self.saved,self.journal,self.receipt,self.intent,source_reader=source,browser=browser)['result'],'UNVERIFIED')
        malformed=dict(self.observation,private='do not report');source=Mock(side_effect=[deepcopy(self.sample),deepcopy(self.sample)])
        report=verify.run(self.saved,self.journal,self.receipt,self.intent,source_reader=source,browser=Mock(return_value=malformed))
        self.assertEqual(report['result'],'UNVERIFIED');self.assertNotIn('do not report',json.dumps(report))

    def test_invalid_scope_rejected_before_browser_import(self):
        with self.assertRaises(ValueError):verify.observe('CB_bad/',[{'chapterUid':1}],{'wr_vid':'1'})
        with self.assertRaises(ValueError):verify.observe('CB_Synthetic',[{'chapterUid':1}],{'unknown':'secret'})

    def test_empty_response_requires_success_complete_scope_and_valid_schema(self):
        encode=lambda value:json.dumps(value).encode()
        self.assertTrue(verify.empty_bookmark_response(encode({'updated':[],'chapters':[]}),self.state['target']))
        for value in ({'updated':[],'errcode':-1},{'updated':[],'hasMore':1},
                {'updated':[],'bookId':'CB_Other'},{'updated':[{'type':0}]},{'updated':{}},{}):
            with self.subTest(value=value):self.assertFalse(verify.empty_bookmark_response(encode(value),self.state['target']))
        self.assertFalse(verify.empty_bookmark_response(b'{',self.state['target']))


if __name__=='__main__':unittest.main()
