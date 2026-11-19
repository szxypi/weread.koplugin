import copy
import io
import json
from contextlib import redirect_stderr, redirect_stdout
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from test_verify_profile_account import FakeProbe
from verify_owner_profile_account import main, validate_runner


def stage(mode,with_statistics=False):
    return dict(result='PASS',mode=mode,phase='complete',name_matches=True,sqlite_verified=True,
                offline_cache=mode=='reopen',worker_reaped=True,account_isolated=True,credentials_not_on_disk=True,
                statistics_verified=with_statistics,concurrent_started=with_statistics and mode=='live',
                statistics_requests=1 if with_statistics and mode=='live' else 0,
                requests=1 if mode=='live' else 0,forbidden=0,failed_line=0)


def runner(with_statistics=False):
    return dict(result='PASS',tmpfs_profile=True,profile_removed=True,installed_bytes_match=True,
                stages=[stage('live',with_statistics),stage('reopen',with_statistics)])


class OwnerProfileAccountTest(unittest.TestCase):
    def run_main(self,args):
        out=io.StringIO()
        with redirect_stdout(out):code=main(args)
        return code,json.loads(out.getvalue()),out.getvalue()

    def test_default_is_offline_and_requires_paired_options(self):
        with patch('verify_owner_profile_account.SessionStore') as store:
            code,report,_=self.run_main([])
        self.assertEqual(code,0);self.assertEqual(report['result'],'OFFLINE_ONLY');store.assert_not_called()
        with redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):main(['--saved-session'])

    def test_incomplete_private_or_extra_results_are_rejected(self):
        self.assertEqual(validate_runner(json.dumps(runner()).encode())['result'],'PASS')
        self.assertEqual(validate_runner(json.dumps(runner(True)).encode(),True)['result'],'PASS')
        variants=[]
        for key,value in [('profile_removed',False),('installed_bytes_match',False),('tmpfs_profile',1)]:
            item=runner();item[key]=value;variants.append(item)
        for index,key,value in [(0,'requests',0),(1,'requests',1),(0,'forbidden',1),(1,'offline_cache',False),
                                (0,'worker_reaped',False),(0,'name_matches',1),(0,'extra_private','secret')]:
            item=runner();item['stages'][index][key]=value;variants.append(item)
        for item in variants:
            with self.subTest(item=item),self.assertRaises(ValueError):validate_runner(json.dumps(item).encode())
        for index,key,value in [(0,'concurrent_started',False),(0,'statistics_requests',0),
                                (1,'statistics_requests',1),(1,'statistics_verified',False)]:
            item=runner(True);item['stages'][index][key]=value
            with self.subTest(item=item),self.assertRaises(ValueError):validate_runner(json.dumps(item).encode(),True)

    def test_real_flow_sanitizes_and_requires_independent_readback(self):
        session={'vid':'123','cookies':{'wr_vid':'123','wr_skey':'synthetic-secret'}}
        with patch('verify_owner_profile_account.SessionStore') as store,patch('verify_owner_profile_account.NameProbe',FakeProbe),\
             patch('verify_owner_profile_account.save_refreshed_web_session',return_value=False) as save,\
             patch('verify_owner_profile_account.subprocess.run',return_value=SimpleNamespace(returncode=0,stdout=json.dumps(runner()).encode())) as child:
            store.return_value.load.return_value=copy.deepcopy(session)
            code,report,output=self.run_main(['--saved-session','--runner-command','native-runner'])
        self.assertEqual(code,0);self.assertEqual(report['result'],'PASS');self.assertEqual(report['independent_owner_reads'],2)
        self.assertNotIn('synthetic-secret',output);self.assertNotIn('Private synthetic name',output)
        self.assertEqual(json.loads(child.call_args.kwargs['input'])['expected_name'],'Private synthetic name')
        save.assert_called_once()

    def test_failed_runner_never_saves_session(self):
        broken=runner();broken['stages'][1]['requests']=1
        with patch('verify_owner_profile_account.SessionStore') as store,patch('verify_owner_profile_account.NameProbe',FakeProbe),\
             patch('verify_owner_profile_account.save_refreshed_web_session') as save,\
             patch('verify_owner_profile_account.subprocess.run',return_value=SimpleNamespace(returncode=0,stdout=json.dumps(broken).encode())):
            store.return_value.load.return_value={'vid':'123','cookies':{'wr_vid':'123','wr_skey':'synthetic-secret'}}
            code,report,output=self.run_main(['--saved-session','--runner-command','native-runner'])
        self.assertEqual(code,1);self.assertEqual(report['stage'],'native_ui');self.assertNotIn('synthetic-secret',output)
        save.assert_not_called()

    def test_concurrent_statistics_requires_preflight_and_same_owner(self):
        session={'vid':'123','cookies':{'wr_vid':'123','wr_skey':'synthetic-secret'}}
        grant={'vid':'123','accessToken':'synthetic-native-secret','refreshToken':'synthetic-refresh','deviceId':'synthetic-device'}
        with patch('verify_owner_profile_account.SessionStore') as store,patch('verify_owner_profile_account.NameProbe',FakeProbe),\
             patch('verify_owner_profile_account.NativeSessionStore') as native,patch('verify_owner_profile_account.StatisticsProbe') as stats,\
             patch('verify_owner_profile_account.project') as project,patch('verify_owner_profile_account.save_refreshed_web_session',return_value=False),\
             patch('verify_owner_profile_account.subprocess.run',return_value=SimpleNamespace(returncode=0,stdout=json.dumps(runner(True)).encode())) as child:
            store.return_value.load.return_value=copy.deepcopy(session);native.return_value.load.return_value=copy.deepcopy(grant)
            code,report,output=self.run_main(['--saved-session','--with-statistics','--runner-command','native-runner'])
        self.assertEqual(code,0);self.assertEqual(report['statistics_preflight_gets'],1)
        self.assertNotIn('synthetic-native-secret',output);native.return_value.load.assert_called_once_with('123')
        stats.return_value.request.assert_called_once();project.assert_called_once()
        self.assertTrue(json.loads(child.call_args.kwargs['input'])['with_statistics'])

    def test_expired_statistics_preflight_stops_without_dispatch(self):
        grant={'vid':'123','accessToken':'synthetic-native-secret','refreshToken':'synthetic-refresh','deviceId':'synthetic-device'}
        with patch('verify_owner_profile_account.SessionStore') as store,patch('verify_owner_profile_account.NameProbe',FakeProbe),\
             patch('verify_owner_profile_account.NativeSessionStore') as native,patch('verify_owner_profile_account.StatisticsProbe') as stats,\
             patch('verify_owner_profile_account.save_refreshed_web_session') as save,patch('verify_owner_profile_account.subprocess.run') as child:
            store.return_value.load.return_value={'vid':'123','cookies':{'wr_vid':'123','wr_skey':'synthetic-secret'}}
            native.return_value.load.return_value=copy.deepcopy(grant)
            stats.return_value.report={'stages':[{'status':401}]};stats.return_value.request.side_effect=ValueError('expired')
            code,report,output=self.run_main(['--saved-session','--with-statistics','--runner-command','native-runner'])
        self.assertEqual(code,1);self.assertEqual(report['stage'],'statistics_preflight');self.assertEqual(report['statistics_http_status'],401)
        self.assertNotIn('synthetic-native-secret',output);child.assert_not_called();save.assert_not_called()


if __name__=='__main__':unittest.main()
