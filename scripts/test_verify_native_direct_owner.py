"""Opt-in native-only owner verification and redacted reporting."""
from contextlib import redirect_stdout
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import verify_native_direct_owner as task


class NativeDirectOwnerTests(unittest.TestCase):
    def test_default_is_offline(self):
        with patch.object(task,'SessionStore') as saved,patch.object(task,'NativeSessionStore') as native,\
                patch.object(task,'ChapterProbe') as probe,patch.object(task.subprocess,'run') as child,\
                redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]),0)
        saved.assert_not_called();native.assert_not_called();probe.assert_not_called();child.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def test_private_payload_is_not_reported(self):
        sample={'book_id':'42','expected':{'format':'epub','version':1}}
        probe=SimpleNamespace(request=lambda *_args,**_kwargs:{'books':[]},
            inspect=lambda *_args:(sample,{'uid':37},{'html':True,'source':b'<p>private text</p>'}))
        result=dict(result='PASS',profile_removed=True,native_requests=5,source_matches=True,offline_reopen=True,
            offline_network_guard=True,web_coordinates=False,manual_time_blocked=True,credential_file_audit=True,
            installed_bytes_match=True,missing_images=0,warning_verified=True)
        child=SimpleNamespace(returncode=0,stdout=task.FRAME+json.dumps(result).encode()+b'\n')
        with patch.object(task,'SessionStore') as saved,patch.object(task,'NativeSessionStore') as native,\
                patch.object(task,'ChapterProbe',return_value=probe),patch.object(task,'state_hash',return_value='same'),\
                patch.object(task,'search_token',return_value='private text'),patch.object(task.subprocess,'run',return_value=child) as run,\
                redirect_stdout(io.StringIO()) as output:
            saved.return_value.load.return_value={'vid':'123'}
            native.return_value.load.return_value={'vid':'123','accessToken':'private-token'}
            self.assertEqual(task.main(['--saved-session','--lua-command','runner']),0)
        self.assertIn('private-token',run.call_args.kwargs['input'].decode())
        for value in ('private-token','private text','"42"'):
            self.assertNotIn(value,output.getvalue())
        report=json.loads(output.getvalue())
        self.assertEqual(report['result'],'NATIVE_DIRECT_OWNER_READONLY_VERIFIED')
        self.assertTrue(report['offline_network_guard'])

    def test_explicit_session_requires_private_command(self):
        with self.assertRaises(SystemExit),redirect_stdout(io.StringIO()):task.main(['--saved-session'])


if __name__=='__main__':unittest.main()
