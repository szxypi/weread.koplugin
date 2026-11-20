"""Offline tests of native fixture coordination; no account or network."""
import contextlib
from copy import deepcopy
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import Mock,patch

from cb_fixture_bookmark_trial import Intent,prepare
from test_cb_fixture_highlight_trial import fixture as source_fixture
from test_secure_native_session import Backend
from verify_cb_fixture_bookmark_native import Observer, TrialFailure, main, run, run_ui


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

    def test_created_hook_is_guarded_before_deletion_and_not_called_during_dry_run(self):
        _,baseline,plan,body=fixture();intent=Intent(Backend());state=deepcopy(baseline);seen=[]
        process=SimpleNamespace(stdin=io.BytesIO(),stdout=io.BytesIO(),wait=lambda **_kwargs:0)
        def hook(payload,actual,target):
            self.assertEqual(payload,{'synthetic':True});self.assertEqual(actual,body)
            self.assertEqual(target['id'],'synthetic-new');self.assertEqual(intent.read()[0]['phase'],'created')
            seen.append(True)
        with patch('verify_cb_fixture_bookmark_native.subprocess.Popen',return_value=process), \
             patch('verify_cb_fixture_bookmark_native.Frames',side_effect=lambda *_args,**_kwargs:FakeFrames(body,state,False)), \
             patch('verify_cb_fixture_bookmark_native.stop'):
            run_ui(['synthetic'],{'synthetic':True},plan,body,baseline,intent,lambda:True,lambda:deepcopy(state),armed=False,on_created=hook)
        self.assertEqual(seen,[])
        process.stdin=io.BytesIO()
        with patch('verify_cb_fixture_bookmark_native.subprocess.Popen',return_value=process), \
             patch('verify_cb_fixture_bookmark_native.Frames',side_effect=lambda *_args,**_kwargs:FakeFrames(body,state,True)), \
             patch('verify_cb_fixture_bookmark_native.stop'):
            run_ui(['synthetic'],{'synthetic':True},plan,body,baseline,intent,lambda:True,lambda:deepcopy(state),armed=True,on_created=hook)
        self.assertEqual(seen,[True]);self.assertEqual(intent.read(),(None,None));self.assertEqual(state,baseline)

    def test_changed_record_during_hook_stops_before_deletion(self):
        _,baseline,plan,body=fixture();intent=Intent(Backend());state=deepcopy(baseline)
        process=SimpleNamespace(stdin=io.BytesIO(),stdout=io.BytesIO(),wait=lambda **_kwargs:0)
        def change(_payload,_body,_target):state['marks']['updated']['synthetic-new']['range']='999'
        with patch('verify_cb_fixture_bookmark_native.subprocess.Popen',return_value=process), \
             patch('verify_cb_fixture_bookmark_native.Frames',return_value=FakeFrames(body,state,True)), \
             patch('verify_cb_fixture_bookmark_native.stop'):
            with self.assertRaises(ValueError):
                run_ui(['synthetic'],{},plan,body,baseline,intent,lambda:True,lambda:deepcopy(state),armed=True,on_created=change)
        self.assertEqual(intent.read()[0]['phase'],'created');self.assertIn('synthetic-new',state['marks']['updated'])

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

    def source_case(self,*,save_failure=False,errors=(),invalid=False):
        from test_verify_cb_fixture_highlight_trial import FakeUpload
        from verify_cb_reading import CbReadingError
        sample,baseline,_,_=fixture();sample['baseline']={'chapter':'0','offset':0,'percent':0}
        sample['chapters']=[{'chapterUid':2,'chapterIdx':2}]
        grant={'vid':'900000','accessToken':'synthetic'};saved={'vid':'900000','cookies':{'wr_vid':'900000'}}
        upload=FakeUpload(sample['book_id'],saved['vid'],object());intent=Intent(Backend())
        errors=list(errors);attempts=[];sleeps=[]
        class NativeStore:
            def load(self,_owner):return grant
        class Source:
            def __init__(self):
                self.samples=[];self.phase='catalog'
                self.last_checks=dict(catalog_unchanged=True,versions_unchanged=True,position_unchanged=True)
            def set_cookie(self,*_args):pass
            def verify_account(self):pass
            def close(self):pass
            def inspect(self,book):
                assert book==sample['book_id'];attempts.append(1)
                if errors:raise CbReadingError(errors.pop(0))
                self.phase='complete';return dict(deepcopy(sample),source='missing marker') if invalid else deepcopy(sample)
        def uploader(_probe,_journal,_grant,_check,source,*,apply,cleanup_gate):
            assert apply;upload.imported=True
            try:verified=source(sample['book_id']) is True
            except Exception:verified=False
            upload.cleaned=cleanup_gate(upload,upload.receipt,upload.state['plan'],sample['book_id'])
            if upload.cleaned:upload.imported=False
            return dict(result='EPUB_IMPORT_AND_SOURCE_VERIFIED' if verified else 'EPUB_IMPORTED_SOURCE_UNVERIFIED',
                        phase='restored' if upload.cleaned else 'imported')
        ui=Mock();observer=Mock()
        with patch('verify_cb_fixture_bookmark_native.save_refreshed_web_session',
                   side_effect=RuntimeError('private synthetic detail') if save_failure else None,return_value=False):
            report=run(saved,None,NativeStore(),grant,upload,intent,['synthetic'],apply=True,uploader=uploader,
                       upload_factory=lambda *_:None,observer_factory=observer,source_factory=Source,ui_runner=ui,source_sleep=sleeps.append)
        return report,upload,intent,observer,ui,attempts,sleeps

    def test_failed_session_save_never_publishes_source_or_launches_native(self):
        report,upload,intent,observer,ui,attempts,sleeps=self.source_case(save_failure=True)
        self.assertEqual(report['source_failure'],'other');self.assertEqual(report['source_phase'],'complete')
        self.assertEqual(report['native_writes_allocated'],0);self.assertTrue(upload.cleaned)
        self.assertNotIn('private synthetic detail',json.dumps(report));observer.assert_not_called();ui.assert_not_called()
        self.assertEqual(intent.read(),(None,None));self.assertEqual(len(attempts),1);self.assertEqual(sleeps,[])

    def test_invalid_marker_reports_only_fixed_booleans_and_does_not_dispatch(self):
        report,upload,intent,observer,ui,attempts,sleeps=self.source_case(invalid=True)
        self.assertEqual(report['source_failure'],'invalid_sample')
        self.assertEqual(report['source_checks'],dict(identity=True,format=True,marker=False,baseline=True))
        self.assertEqual(report['native_writes_allocated'],0);self.assertTrue(upload.cleaned)
        observer.assert_not_called();ui.assert_not_called();self.assertEqual(intent.read(),(None,None))
        self.assertEqual(len(attempts),1);self.assertEqual(sleeps,[])

    def test_changed_source_stops_without_read_retry_or_native_dispatch(self):
        report,upload,intent,observer,ui,attempts,sleeps=self.source_case(errors=['cb_read_baseline_changed'])
        self.assertEqual(report['source_failure'],'cb_read_baseline_changed');self.assertEqual(report['source_phase'],'catalog')
        self.assertTrue(upload.cleaned);observer.assert_not_called();ui.assert_not_called()
        self.assertEqual(intent.read(),(None,None));self.assertEqual(len(attempts),1);self.assertEqual(sleeps,[])

    def test_empty_catalog_read_retries_are_bounded_and_never_dispatch(self):
        report,upload,intent,observer,ui,attempts,sleeps=self.source_case(errors=['cb_catalog_empty']*3)
        self.assertEqual(report['source_failure'],'cb_catalog_empty');self.assertEqual(report['source_attempts'],3)
        self.assertTrue(upload.cleaned);observer.assert_not_called();ui.assert_not_called()
        self.assertEqual(intent.read(),(None,None));self.assertEqual(len(attempts),3);self.assertEqual(sleeps,[2,4])


if __name__=='__main__':unittest.main()
