import contextlib
import io
import json
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import verify_owner_suggestions_ui as subject


class OwnerSuggestionTest(unittest.TestCase):
    def test_default_has_no_account_or_network(self):
        with patch.object(subject, 'SessionStore', side_effect=AssertionError('called')), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(subject.main([]), 0)

    def run_probe(self, stage, exit_code=0):
        saved={'vid':'123'};grant={'vid':'123','accessToken':'private-token'}
        probe=SimpleNamespace(request=lambda *_args,**_kwargs:{})
        body=dict(result='PASS',tmpfs_profile=True,profile_removed=True,stage=stage,reason='none')
        child=SimpleNamespace(returncode=exit_code,stdout=json.dumps(body).encode())
        with patch.object(subject,'SessionStore',return_value=SimpleNamespace(load=lambda:saved)), \
             patch.object(subject,'NativeSessionStore',return_value=SimpleNamespace(load=lambda _owner:grant)), \
             patch.object(subject,'NativeProbe',return_value=probe), \
             patch.object(subject,'project',return_value=['private suggestion']), \
             patch.object(subject,'page',return_value={'books':[{'bookId':'123'}]}), \
             patch.object(subject.subprocess,'run',return_value=child) as runner, \
             contextlib.redirect_stdout(io.StringIO()) as output:
            status=subject.main(['--saved-session','--ui-command','fake-runner'])
        text=output.getvalue()
        self.assertNotIn('private suggestion',text);self.assertNotIn('private-token',text)
        self.assertIn(b'private-token',runner.call_args.kwargs['input'])
        self.assertEqual(saved,{});self.assertEqual(grant,{})
        return status,json.loads(text)

    def valid_stage(self):
        return dict(result='PASS',phase='complete',native_host=True,menu_matches=True,search_matches=True,query_restored=True,
                    workers_reaped=True,credential_audit=True,suggestions=1,books=1,expected_books=1,keyword_matches=True,
                    requests=2,forbidden=0,screenshots=0)

    def test_complete_owner_ui_is_accepted(self):
        status,report=self.run_probe(self.valid_stage())
        self.assertEqual(status,0);self.assertEqual(report['result'],'OWNER_NATIVE_SUGGESTIONS_UI_VERIFIED')

    def test_forbidden_or_incomplete_ui_is_rejected(self):
        for field,value in [('forbidden',1),('requests',3),('requests',True),('screenshots',1),
                            ('credential_audit',False),('books',2),('keyword_matches',False)]:
            with self.subTest(field=field):
                stage=self.valid_stage();stage[field]=value
                status,report=self.run_probe(stage)
                self.assertEqual(status,1);self.assertEqual(report['result'],'UNVERIFIED')


if __name__=='__main__':unittest.main()
