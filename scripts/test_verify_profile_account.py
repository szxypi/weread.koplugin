import io
import json
from contextlib import redirect_stderr, redirect_stdout
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from verify_profile_account import main


class FakeProbe:
    def __init__(self):
        self.cookies=[];self.vid=None;self.name=None;self.authenticated=False;self.reads=0
    def set_cookie(self,key,value):
        self.cookies.append(SimpleNamespace(name=key,value=value,domain='.weread.qq.com',path='/'))
    def verify_account(self):
        self.reads+=1;self.name='Private synthetic name';self.authenticated=True
    def close(self):
        pass


class ProfileAccountVerificationTest(unittest.TestCase):
    def run_main(self,args):
        out=io.StringIO()
        with redirect_stdout(out):code=main(args)
        return code,json.loads(out.getvalue()),out.getvalue()

    def test_default_is_offline(self):
        with patch('verify_profile_account.SessionStore') as store:
            code,report,_=self.run_main([])
        self.assertEqual(code,0);self.assertEqual(report['result'],'OFFLINE_ONLY');store.assert_not_called()

    def test_readonly_flow_keeps_personal_values_out_of_report(self):
        session={'vid':'123','cookies':{'wr_vid':'123','wr_skey':'synthetic-secret'}}
        with patch('verify_profile_account.SessionStore') as store,patch('verify_profile_account.NameProbe',FakeProbe),\
             patch('verify_profile_account.save_refreshed_web_session',return_value=False) as save,\
             patch('verify_profile_account.subprocess.run',return_value=SimpleNamespace(returncode=0,stdout=b'PROFILE_ACCOUNT_LIVE_OK\n')) as child:
            store.return_value.load.return_value=session
            code,report,output=self.run_main(['--saved-session','--lua-command','native-probe'])
        self.assertEqual(code,0);self.assertEqual(report['result'],'PASS');self.assertEqual(report['independent_owner_reads'],2)
        self.assertNotIn('Private synthetic name',output);self.assertNotIn('synthetic-secret',output)
        payload=json.loads(child.call_args.kwargs['input'])
        self.assertEqual(payload['owner'],'123');self.assertEqual(len(payload['name_hash']),64)
        save.assert_called_once()

    def test_failed_native_probe_never_saves_rotation(self):
        session={'vid':'123','cookies':{'wr_vid':'123','wr_skey':'synthetic-secret'}}
        with patch('verify_profile_account.SessionStore') as store,patch('verify_profile_account.NameProbe',FakeProbe),\
             patch('verify_profile_account.save_refreshed_web_session') as save,\
             patch('verify_profile_account.subprocess.run',return_value=SimpleNamespace(returncode=1,stdout=b'PROFILE_ACCOUNT_FETCH_FAILED\n')):
            store.return_value.load.return_value=session
            code,report,output=self.run_main(['--saved-session','--lua-command','native-probe'])
        self.assertEqual(code,1);self.assertEqual(report['stage'],'native_read');self.assertEqual(report['native_result'],'FETCH_FAILED')
        self.assertNotIn('synthetic-secret',output);save.assert_not_called()

    def test_saved_session_requires_a_command(self):
        with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):main(['--saved-session'])


if __name__=='__main__':unittest.main()
