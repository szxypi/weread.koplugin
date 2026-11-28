"""Offline privacy, isolation and cleanup gates for the fixture UI trial."""
from contextlib import redirect_stdout
import copy
import hashlib
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from cb_existing_position_intent import Intent as UiIntent
from cb_fixture_position import plan as fixture_plan
from cb_fixture_position_intent import Intent as SeedIntent
from test_cb_fixture_position import fixture
from test_cb_fixture_position_transport import MemoryBackend
import verify_cb_fixture_manual_trial as task


class TestFixtureManualTrial(unittest.TestCase):
    def test_offline_does_not_open_sessions(self):
        with patch.object(task,'SessionStore') as store,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]),0)
        store.assert_not_called();self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def test_runner_has_private_input_only_on_pipe_and_requires_exact_result(self):
        expected=dict(result='PASS',profile_removed=True,installed_bytes_match=True,native_choice=True,actual_source=True,
            upload_confirmed=True,fresh_process=True,pending_cleared=True,journal_cleared=True,automatic_disabled=True,
            writes=2,denied=0,credentials_not_persisted=True)
        payload=dict(cookies=dict(wr_skey='private-cookie'),source='private-source')
        with patch.object(task.subprocess,'run',return_value=SimpleNamespace(returncode=0,stdout=json.dumps(expected).encode())) as child:
            self.assertTrue(task.ui_runner(['runner'],payload,600,800,167))
        self.assertNotIn('private',' '.join(child.call_args.args[0]))
        self.assertEqual(json.loads(child.call_args.kwargs['input']),payload)
        for bad in (dict(expected,writes=1),dict(expected,denied=1),dict(expected,profile_removed=False),dict(expected,extra='bad')):
            with patch.object(task.subprocess,'run',return_value=SimpleNamespace(returncode=0,stdout=json.dumps(bad).encode())):
                with self.assertRaises(ValueError):task.ui_runner(['runner'],payload,600,800,167)

    def test_success_and_unknown_ui_effect_gate_cleanup(self):
        for success in (True,False):
            with self.subTest(success=success):self.run_trial(success)

    def run_trial(self,success):
        target,sample=fixture();sample['source_raw_sha256']=hashlib.sha256(sample['source'].encode()).hexdigest()
        source_plan=fixture_plan(target,sample);state={'offset':source_plan['first'],'summary':'seed summary'}
        owner='900000';grant=dict(vid=owner);saved=dict(vid=owner,cookies={'wr_vid':owner,'wr_skey':'synthetic-session'})
        class FakeJournal:
            def __init__(self):self.data=dict(phase='imported',target=target,attempt='a'*32,plan=dict(owner=owner));self.receipt=object()
            def read(self):return self.data,self.receipt
        class FakeNative:
            def load(self,_owner):return grant
        class FakeBase:
            def __init__(self):
                self.authenticated=False;self.samples=[];self.progress={};self.last_checks=dict(catalog_unchanged=True,versions_unchanged=True,position_unchanged=True)
            def set_cookie(self,*_args):pass
            def verify_account(self):self.authenticated=True
            def close(self):pass
            def inspect(self,book):assert book==target;return copy.deepcopy(sample)
        class FakeWeb(FakeBase):
            def inspect(self,book):
                value=super().inspect(book)
                self.progress[(book,'progress_before')]=dict(book=dict(bookId=target,chapterUid=9,chapterIdx=1,
                    chapterOffset=state['offset'],progress=1,summary=state['summary']))
                return value
        class FakeRead(FakeBase):
            def request(self,_stage,_url):
                return dict(book=dict(bookId=target,chapterUid=9,chapterIdx=1,chapterOffset=state['offset'],progress=1,summary=state['summary']))
        class FakeSeed:
            def __init__(self,_plan,_owner,authority):self.authority=authority;self.authenticated=False
            def set_cookie(self,*_args):pass
            def verify_account(self):self.authenticated=True
            def execute(self,_baseline):
                assert self.authority();return dict(result='PASS',writes=4)
            def close(self):pass
        calls=[]
        def fake_ui(_runner,payload,width,height,dpi):
            calls.append((width,height,dpi))
            if not success:raise ValueError('unknown')
            state.update(offset=payload['next_offset'],summary=payload['expected_summary']);return True
        journal=FakeJournal();seed=SeedIntent(backend=MemoryBackend());ui=UiIntent(backend=MemoryBackend())
        def fake_upload(_probe,provided,_grant,_same,read_source,*,apply,cleanup_gate):
            self.assertTrue(apply);self.assertIs(provided,journal);self.assertTrue(read_source(target))
            allowed=cleanup_gate(journal,journal.receipt,journal.data['plan'],target)
            self.assertEqual(allowed,success)
            return dict(result='EPUB_IMPORT_AND_SOURCE_VERIFIED' if allowed else 'UNVERIFIED',phase='restored' if allowed else 'imported',
                cos_put_attempts=1,notify_posts=1,cleanup_posts=int(allowed))
        with patch.object(task,'CbReadingProbe',FakeBase),patch.object(task,'Web',FakeWeb),patch.object(task,'WebSourceProbe',FakeRead),\
             patch.object(task,'PositionProbe',FakeSeed),patch.object(task,'ui_runner',side_effect=fake_ui),\
             patch.object(task,'save_refreshed_web_session',return_value=False):
            report=task.run(saved,None,FakeNative(),grant,journal,seed,ui,['runner'],apply=True,upload_factory=lambda *_:None,upload_run=fake_upload)
        self.assertEqual(report['result'],'FIXTURE_MANUAL_SYNC_VERIFIED' if success else 'UNVERIFIED')
        self.assertEqual(len(calls),2 if success else 1)
        self.assertEqual(report['ui_writes_allocated'],4 if success else 2)
        self.assertNotIn(target,json.dumps(report));self.assertNotIn('synthetic-session',json.dumps(report))
        with self.assertRaises(Exception):ui.reserve(owner,target,'a'*32,'b'*64)


if __name__=='__main__':unittest.main()
