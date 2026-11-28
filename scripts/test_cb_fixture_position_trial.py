"""Offline orchestration tests for a newly uploaded synthetic fixture."""
from contextlib import redirect_stderr,redirect_stdout
import copy
import io
import json
import unittest
from unittest.mock import patch
from cb_fixture_position_intent import Intent
from test_cb_fixture_position import fixture
from test_cb_fixture_position_transport import MemoryBackend
import verify_cb_fixture_position_trial as task


class FakeWeb:
    def __init__(self):self.authenticated=False;self.samples=[];self.last_checks={'catalog_unchanged':True,'versions_unchanged':True,'position_unchanged':True}
    def set_cookie(self,_key,_value):pass
    def verify_account(self):self.authenticated=True
    def inspect(self,target):
        book,sample=fixture();assert target==book
        return copy.deepcopy(sample)
    def close(self):pass


class FakeNative:
    def __init__(self,grant):self.grant=grant
    def load(self,_owner):return self.grant


class FakeJournal:
    def __init__(self,owner,target):self.state=dict(phase='imported',target=target,attempt='a'*32,plan=dict(owner=owner));self.receipt=object()
    def read(self):return self.state,self.receipt


class FakePosition:
    outcome='PASS'
    def __init__(self,_plan,_owner,authority):self.authority=authority;self.authenticated=False
    def set_cookie(self,_key,_value):pass
    def verify_account(self):self.authenticated=True
    def execute(self,_baseline):
        assert self.authority()
        return dict(result=self.outcome,writes=4 if self.outcome=='PASS' else 3)
    def close(self):pass


class TestFixtureTrial(unittest.TestCase):
    def test_offline_does_not_access_credentials(self):
        with patch.object(task,'SessionStore') as store,redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        store.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')
        with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):task.main(['--apply'])

    def test_exact_new_fixture_may_complete_and_cleanup(self):
        self.check_result('PASS',True)

    def test_uncertain_position_blocks_fixture_cleanup(self):
        self.check_result('UNVERIFIED',False)

    def check_result(self,outcome,expected_cleanup):
        target,_=fixture();owner='900000';grant=dict(vid=owner)
        saved=dict(vid=owner,cookies={'wr_vid':owner,'wr_skey':'synthetic-session'})
        journal=FakeJournal(owner,target);intent=Intent(backend=MemoryBackend());FakePosition.outcome=outcome
        def upload_run(_probe,provided,_grant,_same,read_source,*,apply,cleanup_gate):
            self.assertTrue(apply);self.assertIs(provided,journal);self.assertTrue(read_source(target))
            cleanup=cleanup_gate(journal,journal.receipt,journal.state['plan'],target)
            self.assertEqual(cleanup,expected_cleanup)
            return dict(result='EPUB_IMPORT_AND_SOURCE_VERIFIED' if cleanup else 'UNVERIFIED',phase='restored' if cleanup else 'imported',
                        cos_put_attempts=1,notify_posts=1,cleanup_posts=int(cleanup))
        with patch.object(task,'CbReadingProbe',FakeWeb),patch.object(task,'PositionProbe',FakePosition),\
             patch.object(task,'save_refreshed_web_session',return_value=False):
            result=task.run(saved,None,FakeNative(grant),grant,journal,intent,apply=True,
                            upload_factory=lambda *_:None,upload_run=upload_run)
        self.assertEqual(result['result'],'FIXTURE_POSITION_VERIFIED' if expected_cleanup else 'UNVERIFIED')
        self.assertEqual(result['account_data_writes'],7 if expected_cleanup else 5)
        self.assertNotIn(target,json.dumps(result));self.assertNotIn('synthetic-session',json.dumps(result))
        with self.assertRaises(Exception):intent.reserve(owner,target,'a'*32)


if __name__=='__main__':unittest.main()
