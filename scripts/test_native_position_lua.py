"""Private protocol comparison boundary: no actual credentials or network."""
from contextlib import redirect_stdout
from copy import deepcopy
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import Mock,patch
from test_secure_native_session import credentials
from native_txt_read_model import body
from test_native_txt_position import point,progress
import verify_native_position_lua as task


class NativePositionLuaTests(unittest.TestCase):
    def execute(self,mutate=None,raw=None,returncode=0):
        expected=body(credentials(),point(),0,'synthetic-guest',1700000000,123,'+08:00')
        def run(command,**kwargs):
            self.assertEqual(command,['synthetic-lua']);self.assertEqual(kwargs['timeout'],60)
            private=json.loads(kwargs['input']);self.assertEqual(private['credentials'],credentials());self.assertEqual(private['point'],point())
            reply={'result':'PASS','body':deepcopy(expected)}
            if mutate:mutate(reply)
            return SimpleNamespace(returncode=returncode,stdout=raw if raw is not None else json.dumps(reply).encode())
        task.compare(credentials(),point(),0,'synthetic-guest',1700000000,123,'+08:00',None,['synthetic-lua'],runner=run)
    def test_complete_payload_comparison_uses_private_pipes(self):self.execute()
    def test_equivalent_numbers_do_not_allow_boolean_counters(self):
        self.assertTrue(task.equivalent({'x':17.0},{'x':17}))
        self.assertFalse(task.equivalent({'x':0},{'x':False}));self.assertFalse(task.equivalent({'x':1},{'x':True}))
    def test_empty_hours_object_is_not_an_empty_json_array(self):
        with self.assertRaises(ValueError):self.execute(lambda v:v['body'].update(hours={}))
    def test_truncated_summary_changed_signature_or_fields_are_rejected(self):
        for change in ({'summary':'truncated'},{'signature':'0'*64},{'chapterOffset':13},{'readingTime':True},{'extra':0}):
            with self.subTest(change=change),self.assertRaises(ValueError):self.execute(lambda v:v['body'].update(change))
    def test_unknown_result_extra_output_or_oversize_output_is_rejected(self):
        for raw in (b'PRIVATE_DIAGNOSTIC',b'x'*65537,b'{"result":"PASS"}'):
            with self.assertRaises(ValueError):self.execute(raw=raw)
        with self.assertRaises(ValueError):self.execute(lambda v:v.update(extra=True))
    def test_child_failure_cannot_be_reported_as_matching(self):
        with self.assertRaises(ValueError):self.execute(returncode=1)
    def test_optional_chapter_progress_is_compared_only_when_observed(self):
        expected=body(credentials(),point(),0,'synthetic-guest',1700000000,123,'+08:00',12.5)
        def run(command,**kwargs):
            self.assertEqual(json.loads(kwargs['input'])['chapter_progress'],12.5)
            return SimpleNamespace(returncode=0,stdout=json.dumps({'result':'PASS','body':expected}).encode())
        task.compare(credentials(),point(),0,'synthetic-guest',1700000000,123,'+08:00',12.5,['synthetic-lua'],runner=run)
    def test_actual_response_is_compared_as_a_separate_snapshot(self):
        def run(command,**kwargs):
            private=json.loads(kwargs['input']);self.assertEqual(private['native_response'],progress())
            return SimpleNamespace(returncode=0,stdout=json.dumps({'result':'PASS','body':body(credentials(),point(),0,'synthetic-guest',1700000000,123,'+08:00'),
                'snapshot':{'position':point(),'counts':{'readingTime':40,'recordReadingTime':50,'ttsTime':0}}}).encode())
        task.compare(credentials(),point(),0,'synthetic-guest',1700000000,123,'+08:00',None,['synthetic-lua'],runner=run,native_response=progress())
    def test_wrong_counter_snapshot_cannot_match(self):
        for changed in ({'readingTime':True},{'recordReadingTime':49}):
            def run(command,**kwargs):
                return SimpleNamespace(returncode=0,stdout=json.dumps({'result':'PASS','body':body(credentials(),point(),0,'synthetic-guest',1700000000,123,'+08:00'),
                    'snapshot':{'position':point(),'counts':dict(readingTime=40,recordReadingTime=50,ttsTime=0)|changed}}).encode())
            with self.assertRaises(ValueError):task.compare(credentials(),point(),0,'synthetic-guest',1700000000,123,'+08:00',None,['synthetic-lua'],runner=run,native_response=progress())
    def test_oversize_private_input_never_launches_a_child(self):
        raw=progress();raw['extra']='x'*65536;runner=Mock()
        with self.assertRaises(ValueError):task.compare(credentials(),point(),0,'synthetic-guest',1700000000,123,'+08:00',None,['synthetic-lua'],runner=runner,native_response=raw)
        runner.assert_not_called()
    def test_default_does_not_load_credentials_or_launch_a_child(self):
        with patch.object(task,'SessionStore') as store,redirect_stdout(io.StringIO()) as out:self.assertEqual(task.main([]),0)
        store.assert_not_called();self.assertEqual(json.loads(out.getvalue())['account_data_posts'],0)
    def test_private_exception_is_never_reported(self):
        with patch.object(task,'SessionStore',side_effect=ValueError('synthetic private credential')),redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main(['--saved-session','--lua-command','synthetic-lua']),1)
        self.assertNotIn('synthetic private',out.getvalue())


if __name__=='__main__':unittest.main()
