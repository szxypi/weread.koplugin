"""Read-only CLI boundaries and captured comparisons; no saved credential access."""
from contextlib import redirect_stdout,redirect_stderr
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import verify_thought_edit_contract as task
from thought_edit_contract import make
from test_annotation_experiment import preparation,marks,info,observation
from test_secure_native_session import credentials
from test_eink_login import Opener


class ReadOnlyTests(unittest.TestCase):
    def test_default_never_loads_credentials_or_opens_network(self):
        with patch.object(task,'SessionStore') as web,patch.object(task,'NativeSessionStore') as native,patch.object(task,'AnnotationProbe') as probe,redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]),0)
        for dependency in [web,native,probe]:dependency.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def test_comparison_requires_explicit_saved_session(self):
        with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):task.main(['--lua-command','forbidden'])

    def run_saved(self,bad=False):
        opener=Opener([*preparation(),marks(),info(),*observation()]);probe=task.AnnotationProbe(opener,sleep=lambda _delay:None)
        def child(_command,**options):
            payload=json.loads(options['input']);text=payload['content'];s=payload['snapshot']
            plans=[make(s,'create',payload['reference'],text,marks=payload['marks'],metadata=payload['metadata'],owner=payload['owner']),
                   make(s,'edit',payload['thought'],text),make(s,'delete',payload['thought'])]
            return SimpleNamespace(returncode=int(bad),stdout=b'\nWEREAD_THOUGHT_CONTRACT_RESULT='+json.dumps(plans).encode())
        with patch.object(task,'SessionStore') as web,patch.object(task,'NativeSessionStore') as native,patch.object(task,'AnnotationProbe',return_value=probe),patch.object(task.subprocess,'run',side_effect=child),redirect_stdout(io.StringIO()) as output:
            web.return_value.load.return_value=dict(vid='900000');native.return_value.load.return_value=credentials()
            code=task.main(['--saved-session','--lua-command','synthetic'])
        return code,json.loads(output.getvalue()),opener

    def test_saved_contract_uses_get_only_and_checks_original_state(self):
        code,report,opener=self.run_saved()
        self.assertEqual(code,0);self.assertTrue(report['lua_matches'] and report['original_state_unchanged'])
        self.assertEqual(report['plans'],3);self.assertEqual(report['data_posts'],0)
        self.assertTrue(all(request.get_method()=='GET' for request in opener.requests))
        for value in ['existing-note','Private original thought','Private quote',credentials()['accessToken']]:self.assertNotIn(value,json.dumps(report))

    def test_comparison_failure_is_redacted_and_never_falls_back_to_a_post(self):
        code,report,opener=self.run_saved(True)
        self.assertEqual(code,1);self.assertEqual(report['reason'],'thought_contract_unverified')
        self.assertTrue(all(request.get_method()=='GET' for request in opener.requests));self.assertNotIn('existing-note',json.dumps(report))


if __name__=='__main__':unittest.main()
