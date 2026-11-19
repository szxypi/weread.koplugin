"""Offline tests of native fixture coordination; no account or network."""
import contextlib
from copy import deepcopy
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from cb_fixture_bookmark_trial import Intent,prepare
from test_cb_fixture_highlight_trial import fixture as source_fixture
from test_secure_native_session import Backend
from verify_cb_fixture_bookmark_native import Observer, TrialFailure, main, run_ui


def fixture():
    sample,baseline,_plan,_body=source_fixture()
    plan,body=prepare('900000','CB_Synthetic42','a'*32,sample,1,baseline)
    return sample,baseline,plan,body


class FakeFrames:
    def __init__(self, body, state, armed, *, invalid=False):
        self.body=body;self.state=state;self.armed=armed;self.invalid=invalid;self.step=0
    def next(self):
        self.step+=1
        if not self.armed:
            return ('STEP',{'seq':0,'preview':self.body}) if self.step==1 else ('RESULT',self.result(False))
        if self.step==1:
            self.state['marks']['updated']['synthetic-new']=dict(self.body,bookmarkId='synthetic-new')
            return 'STEP',{'seq':1,'created_id':'wrong' if self.invalid else 'synthetic-new'}
        if self.step==2:
            self.state['marks']['updated'].clear();return 'STEP',{'seq':2,'created_id':'synthetic-new'}
        return 'RESULT',self.result(True)
    @staticmethod
    def result(armed):
        return dict(result='PASS' if armed else 'DRY_RUN',profile_removed=True,installed_bytes_match=True,stage=None,
                    native_controls=True,writes=2 if armed else 0,fresh_offline=armed,credentials_not_persisted=True)


class TestNativeFixture(unittest.TestCase):
    def test_offline_default_does_not_open_login(self):
        with patch('verify_cb_fixture_bookmark_native.SessionStore') as store,contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main([]),0)
        store.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_host_observer_has_no_write_method(self):
        observer=Observer('CB_Synthetic42',{'vid':'900000'},lambda:True,Intent(Backend()))
        self.assertEqual(observer.max_gets,80)
        with self.assertRaises(ValueError):observer.request('anything','https://i.weread.qq.com/book/addBookmark',{})

    def run_case(self,armed,invalid=False):
        _,baseline,plan,body=fixture();state=deepcopy(baseline);intent=Intent(Backend())
        process=SimpleNamespace(stdin=io.BytesIO(),stdout=io.BytesIO(),wait=lambda **_kwargs:0)
        frames=FakeFrames(body,state,armed,invalid=invalid)
        with patch('verify_cb_fixture_bookmark_native.subprocess.Popen',return_value=process), \
             patch('verify_cb_fixture_bookmark_native.Frames',return_value=frames), \
             patch('verify_cb_fixture_bookmark_native.stop'):
            def execute():return run_ui(['synthetic'],{},plan,body,baseline,intent,lambda:True,lambda:deepcopy(state),armed=armed)
            if invalid:
                with self.assertRaises(ValueError):execute()
                return intent,state
            result=execute()
        self.assertEqual(result['writes'],2 if armed else 0);self.assertEqual(intent.read(),(None,None))
        self.assertEqual(state,baseline)

    def test_dry_run_blocks_and_real_run_requires_two_readbacks(self):
        self.run_case(False);self.run_case(True)

    def test_mismatched_created_id_keeps_intent_and_blocks_replay(self):
        intent,state=self.run_case(True,invalid=True)
        self.assertEqual(intent.read()[0]['phase'],'create_pending')
        self.assertIn('synthetic-new',state['marks']['updated'])

    def test_runner_failure_reports_only_bounded_stage(self):
        _,baseline,plan,body=fixture();intent=Intent(Backend())
        process=SimpleNamespace(stdin=io.BytesIO(),stdout=io.BytesIO(),wait=lambda **_kwargs:1)
        class Broken:
            def next(self):return 'RESULT',dict(result='UNVERIFIED',stage=dict(result='UNVERIFIED',phase='prepare',failure_line=138))
        with patch('verify_cb_fixture_bookmark_native.subprocess.Popen',return_value=process), \
             patch('verify_cb_fixture_bookmark_native.Frames',return_value=Broken()), \
             patch('verify_cb_fixture_bookmark_native.stop'):
            with self.assertRaises(TrialFailure) as caught:
                run_ui(['synthetic'],{},plan,body,baseline,intent,lambda:True,lambda:deepcopy(baseline),armed=False)
        self.assertEqual(caught.exception.stage,dict(result='UNVERIFIED',phase='prepare',failure_line=138))
        self.assertEqual(intent.read(),(None,None))


if __name__=='__main__':unittest.main()
