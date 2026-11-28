import contextlib
import io
import json
import unittest
from unittest.mock import patch

from test_personal_upload_trial import FakeProbe
from test_secure_native_session import Backend, credentials
from verify_cb_txt_fixture import Receipt
from verify_cb_txt_native_fixture import (BODY, SHORT_BODY, SINGLE_BODY, MARKER, Journal, ShortJournal, SingleJournal,
                                          command, execute, execute_short, execute_single, main, verify_native)

TARGET='CB_synthetic123'
CANDIDATE='/validation/cb-dry-candidate-'+'a'*64+'.zip'


class NativeTxtFixtureTests(unittest.TestCase):
    def previous(self):
        return ({'target':'CB_previoustxt','plan':{'owner':credentials()['vid']}},'token',b'receipt')

    def test_fixture_is_large_unique_and_scoped(self):
        self.assertTrue(10000 < len(BODY) < 65536)
        self.assertTrue(1024 < len(SHORT_BODY) < 4096)
        self.assertLess(len(SINGLE_BODY),1024)
        self.assertEqual(BODY.count(MARKER.encode()),1)
        self.assertIn('--cb-reading',command(CANDIDATE,1264,1680,300))
        for path in ('/validation/cb-dry-candidate-bad.zip','/validation/../secret.zip'):
            with self.assertRaises(ValueError):command(path,600,800,167)
        with self.assertRaises(ValueError):command(CANDIDATE,1,1,1)

    def test_offline_default_does_not_open_sessions(self):
        with patch('verify_cb_txt_native_fixture.SessionStore',side_effect=AssertionError('opened')):
            with contextlib.redirect_stdout(io.StringIO()) as output:self.assertEqual(main([]),0)
        self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def test_distinct_scope_is_single_use_and_preserves_prior(self):
        journal=Journal(Backend());receipt=Receipt(Backend());probe=FakeProbe()
        class Group:
            def read(self):return {'target':'CB_oldgroup'},'group-token'
        with patch('verify_cb_txt_native_fixture.GroupJournal',Group):
            result=execute(probe,journal,receipt,credentials(),lambda *_:True,lambda _:True,lambda:True,
                           self.previous,apply=True,sleep=lambda _:None,now=lambda:1000)
        self.assertEqual(result['result'],'TXT_IMPORT_AND_SOURCE_VERIFIED')
        self.assertEqual(tuple(probe.attempts.values()),(1,1,1,1))
        self.assertEqual(journal.read()[0]['phase'],'restored')
        with self.assertRaises(ValueError):
            execute(probe,journal,receipt,credentials(),lambda *_:True,lambda _:True,lambda:True,self.previous,apply=True)

    def test_prior_or_group_identity_collision_never_cleans(self):
        for collision in ('prior','group'):
            journal=Journal(Backend());receipt=Receipt(Backend());probe=FakeProbe()
            def prior():
                row=self.previous()
                if collision=='prior':row[0]['target']=TARGET
                return row
            class Group:
                def read(self):return {'target':TARGET if collision=='group' else 'CB_oldgroup'},'group-token'
            with patch('verify_cb_txt_native_fixture.GroupJournal',Group):
                result=execute(probe,journal,receipt,credentials(),lambda *_:True,lambda _:True,lambda:True,
                               prior,apply=True,sleep=lambda _:None,now=lambda:1000)
            self.assertEqual(result['result'],'UNVERIFIED')
            self.assertEqual(probe.attempts['cleanup'],0)

    def test_short_fixture_uses_distinct_consumed_scope_and_preserves_both_trials(self):
        journal=ShortJournal(Backend());receipt=Receipt(Backend());probe=FakeProbe()
        def prior_long():return ({'target':'CB_previousnative','plan':{'owner':credentials()['vid']}},'token2',b'receipt2')
        class Group:
            def read(self):return {'target':'CB_oldgroup'},'group-token'
        with patch('verify_cb_txt_native_fixture.GroupJournal',Group):
            result=execute_short(probe,journal,receipt,credentials(),lambda *_:True,lambda _:True,lambda:True,
                                 self.previous,prior_long,apply=True,sleep=lambda _:None,now=lambda:1000)
        self.assertEqual(result['result'],'TXT_IMPORT_AND_SOURCE_VERIFIED')
        self.assertEqual(journal.read()[0]['phase'],'restored')
        self.assertEqual(tuple(probe.attempts.values()),(1,1,1,1))
        with self.assertRaises(ValueError):
            execute_short(probe,journal,receipt,credentials(),lambda *_:True,lambda _:True,lambda:True,
                          self.previous,prior_long,apply=True)

    def test_single_fixture_preserves_three_prior_scopes_and_cannot_replay(self):
        journal=SingleJournal(Backend());receipt=Receipt(Backend());probe=FakeProbe()
        def prior(i):return lambda:({'target':'CB_prior'+str(i),'plan':{'owner':credentials()['vid']}},'token'+str(i),b'receipt')
        class Group:
            def read(self):return {'target':'CB_oldgroup'},'group-token'
        previouses=(prior(1),prior(2),prior(3))
        with patch('verify_cb_txt_native_fixture.GroupJournal',Group):
            result=execute_single(probe,journal,receipt,credentials(),lambda *_:True,lambda _:True,lambda:True,
                                  previouses,apply=True,sleep=lambda _:None,now=lambda:1000)
        self.assertEqual(result['result'],'TXT_IMPORT_AND_SOURCE_VERIFIED')
        self.assertEqual(journal.read()[0]['phase'],'restored')
        self.assertEqual(tuple(probe.attempts.values()),(1,1,1,1))
        with self.assertRaises(ValueError):
            execute_single(probe,journal,receipt,credentials(),lambda *_:True,lambda _:True,lambda:True,previouses,apply=True)

    def test_real_reader_result_requires_txt_and_full_readback(self):
        class Store:
            def load(self):return {'vid':'1','cookies':{'wr_vid':'1'}}
        class Web:
            def __init__(self):self.samples=[]
            def set_cookie(self,*_args):pass
            def verify_account(self):pass
            def request(self,*_args):return {'books':[{'bookId':TARGET}]}
            def close(self):pass
        base=dict(result='CB_NATIVE_READING_VERIFIED',source_format='web_txt',same_owner_verified=True,
                  source_text_matched=True,fresh_offline_process=True,cloud_position_unchanged=True,
                  account_data_posts=0,authentication_posts=0,private_data_on_regular_disk=False,screenshots=0)
        calls=[]
        def reader(_args,**scope):calls.append(scope);print(json.dumps(base));return 0
        with patch('verify_cb_txt_native_fixture.save_refreshed_web_session'):
            self.assertTrue(verify_native(TARGET,CANDIDATE,(600,800,167),store=Store(),probe_factory=Web,reader=reader))
            self.assertEqual(calls[0]['expected_book_id'],TARGET)
            self.assertEqual(calls[0]['expected_source_text'],MARKER)
            for key,value in (('source_format','web_xhtml'),('fresh_offline_process',False),('account_data_posts',1),
                              ('account_data_posts',False),('authentication_posts',False),('screenshots',False)):
                bad=dict(base);bad[key]=value
                def bad_reader(_args,**_scope):print(json.dumps(bad));return 0
                with self.subTest(key=key),self.assertRaises(ValueError):
                    verify_native(TARGET,CANDIDATE,(600,800,167),store=Store(),probe_factory=Web,reader=bad_reader)

            single=dict(base,result='CB_NATIVE_SINGLE_PAGE_READING_VERIFIED',page_turn_tested=False,
                        ui={'stages':[{'pages':1},{'pages':1}]})
            def single_reader(_args,**scope):
                self.assertTrue(scope['single_page']);print(json.dumps(single));return 0
            self.assertTrue(verify_native(TARGET,CANDIDATE,(600,800,167),store=Store(),probe_factory=Web,reader=single_reader,single_page=True))
            single['ui']['stages'][1]['pages']=2
            with self.assertRaises(ValueError):
                verify_native(TARGET,CANDIDATE,(600,800,167),store=Store(),probe_factory=Web,reader=single_reader,single_page=True)
            single['ui']['stages'][1]['pages']=True
            with self.assertRaises(ValueError):
                verify_native(TARGET,CANDIDATE,(600,800,167),store=Store(),probe_factory=Web,reader=single_reader,single_page=True)

    def test_failure_diagnostics_discard_private_content(self):
        class Store:
            def load(self):return {'vid':'1','cookies':{'wr_vid':'1'}}
        class Web:
            def __init__(self):self.samples=[]
            def set_cookie(self,*_args):pass
            def verify_account(self):pass
            def request(self,*_args):return {'books':[{'bookId':TARGET}]}
            def close(self):pass
        def failed(_args,**_scope):
            print(json.dumps({'result':'UNVERIFIED','ui':{'result':'UNVERIFIED','stages':[{'phase':'private secret','failed_line':42}]}}));return 1
        diagnostics={}
        with patch('verify_cb_txt_native_fixture.save_refreshed_web_session'),self.assertRaises(ValueError):
            verify_native(TARGET,CANDIDATE,(600,800,167),store=Store(),probe_factory=Web,reader=failed,diagnostics=diagnostics)
        self.assertEqual(diagnostics['stages'],[{'phase':'other','failed_line':42}])
        self.assertEqual(diagnostics['source_format'],'unavailable')
        self.assertNotIn('private secret',json.dumps(diagnostics))


if __name__=='__main__':unittest.main()
