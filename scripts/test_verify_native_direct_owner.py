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

    def test_home_requires_every_private_verification(self):
        sample={'book_id':'42','expected':{'format':'epub','version':1}}
        probe=SimpleNamespace(request=lambda *_args,**_kwargs:{'books':[]},
            inspect=lambda *_args:(sample,{'uid':37},{'html':True,'source':b'<p>private text</p>'}))
        result=dict(result='PASS',profile_removed=True,native_requests=5,source_matches=True,home_record=True,
            offline_home_resume=True,page_restored=True,network_blocked=True,credential_file_audit=True,installed_bytes_match=True)
        marker=b'\nWEREAD_DIRECT_HOME_OWNER_RUN='
        for valid in (True,False):
            result['page_restored']=valid
            child=SimpleNamespace(returncode=0,stdout=marker+json.dumps(result).encode()+b'\n')
            with patch.object(task,'SessionStore') as saved,patch.object(task,'NativeSessionStore') as native,\
                    patch.object(task,'ChapterProbe',return_value=probe),patch.object(task,'state_hash',return_value='same'),\
                    patch.object(task,'search_token',return_value='private text'),patch.object(task.subprocess,'run',return_value=child),\
                    redirect_stdout(io.StringIO()) as output:
                saved.return_value.load.return_value={'vid':'123'}
                native.return_value.load.return_value={'vid':'123','accessToken':'private-token'}
                self.assertEqual(task.main(['--saved-session','--home','--lua-command','runner']),0 if valid else 1)
            report=json.loads(output.getvalue())
            self.assertEqual(report['result'],'NATIVE_DIRECT_HOME_OWNER_READONLY_VERIFIED' if valid else 'UNVERIFIED')
            self.assertNotIn('private text',output.getvalue())
            self.assertNotIn('private-token',output.getvalue())

    def test_full_ui_cannot_be_claimed_by_fixture_only_runner(self):
        sample={'book_id':'42','expected':{'format':'epub','version':1}}
        probe=SimpleNamespace(request=lambda *_args,**_kwargs:{'books':[]},
            inspect=lambda *_args:(sample,{'uid':37},{'html':True,'source':b'<p>private text</p>'}))
        result=dict(result='PASS',profile_removed=True,native_requests=5,source_matches=True,home_record=True,
            offline_home_resume=True,page_restored=True,network_blocked=True,credential_file_audit=True,installed_bytes_match=True)
        marker=b'\nWEREAD_DIRECT_HOME_OWNER_RUN='
        for full in (False,True):
            if full:result['full_ui']=True
            child=SimpleNamespace(returncode=0,stdout=marker+json.dumps(result).encode()+b'\n')
            with patch.object(task,'SessionStore') as saved,patch.object(task,'NativeSessionStore') as native,\
                    patch.object(task,'ChapterProbe',return_value=probe),patch.object(task,'state_hash',return_value='same'),\
                    patch.object(task,'search_token',return_value='private text'),patch.object(task.subprocess,'run',return_value=child),\
                    redirect_stdout(io.StringIO()) as output:
                saved.return_value.load.return_value={'vid':'123'}
                native.return_value.load.return_value={'vid':'123','accessToken':'private-token'}
                self.assertEqual(task.main(['--saved-session','--home','--home-full-ui','--lua-command','runner']),0 if full else 1)
            self.assertEqual(json.loads(output.getvalue())['result'],
                'NATIVE_DIRECT_HOME_OWNER_READONLY_VERIFIED' if full else 'UNVERIFIED')

    def test_home_web_progress_is_independently_compared(self):
        sample={'book_id':'42','expected':{'format':'epub','version':1}}
        probe=SimpleNamespace(request=lambda *_args,**_kwargs:{'books':[]},
            inspect=lambda *_args:(sample,{'uid':37},{'html':True,'source':b'<p>private text</p>'}))
        result=dict(result='PASS',profile_removed=True,native_requests=5,source_matches=True,home_record=True,
            offline_home_resume=True,page_restored=True,network_blocked=True,credential_file_audit=True,installed_bytes_match=True,
            full_ui=True)
        marker=b'\nWEREAD_DIRECT_HOME_OWNER_RUN='
        child=SimpleNamespace(returncode=0,stdout=marker+json.dumps(result).encode()+b'\n')
        for changed in (False,True):
            calls=[]
            web=SimpleNamespace(cookies=SimpleNamespace(clear=lambda:None),set_cookie=lambda *_args:None,
                verify_account=lambda:None,request=lambda stage,*_args: calls.append(stage) or {'stage':stage})
            def project(value,*_args,**_kwargs):
                return 2 if changed and value['stage']=='progress_after' else 1
            with patch.object(task,'SessionStore') as saved,patch.object(task,'NativeSessionStore') as native,\
                    patch.object(task,'ChapterProbe',return_value=probe),patch.object(task,'state_hash',return_value='same'),\
                    patch.object(task,'WebSourceProbe',return_value=web),patch.object(task,'reading_position',side_effect=project),\
                    patch.object(task,'search_token',return_value='private text'),patch.object(task.subprocess,'run',return_value=child),\
                    redirect_stdout(io.StringIO()) as output:
                saved.return_value.load.return_value={'vid':'123','cookies':{'wr_skey':'private-token'}}
                native.return_value.load.return_value={'vid':'123','accessToken':'private-token'}
                code=task.main(['--saved-session','--home','--home-full-ui','--compare-web-progress','--lua-command','runner'])
            self.assertEqual(code,1 if changed else 0)
            self.assertEqual(calls,['progress_before','progress_after'])
            report=json.loads(output.getvalue())
            self.assertEqual(report['result'],'UNVERIFIED' if changed else 'NATIVE_DIRECT_HOME_OWNER_READONLY_VERIFIED')
            self.assertEqual(report.get('web_position_unchanged'),None if changed else True)
            self.assertNotIn('private-token',output.getvalue())


if __name__=='__main__':unittest.main()
