"""Offline COS credential shape and narrowly scoped transport checks."""
import contextlib,io,json,unittest
from copy import deepcopy
from unittest.mock import patch
from verify_eink_login import BASE
from verify_personal_upload_preflight import Probe,URL,main,project


def sample():return dict(bucket='synthetic-12345',ObjectName='/prefix/synthetic-book',
    Response=dict(ExpiredTime=2000,Credentials=dict(TmpSecretId='synthetic-id',TmpSecretKey='synthetic-key',Token='synthetic-token')))


class PreflightTest(unittest.TestCase):
    def test_valid_response_contains_only_fixed_booleans(self):
        self.assertEqual(project(sample(),1000),dict(credentials_valid=True,object_path_safe=True,bucket_host_pattern_valid=True,expiration_in_future=True))
    def test_invalid_secret_path_domain_and_expiry_refused(self):
        for bad in ('bucket','key','empty','expired','far','boolean'):
            value=deepcopy(sample())
            if bad=='bucket':value['bucket']='evil.example.com'
            elif bad=='key':value['ObjectName']='/prefix/../private'
            elif bad=='empty':value['Response']['Credentials']['Token']=''
            elif bad=='expired':value['Response']['ExpiredTime']=1000
            elif bad=='far':value['Response']['ExpiredTime']=1000000
            else:value['Response']['ExpiredTime']=True
            with self.subTest(bad=bad),self.assertRaises(ValueError):project(value,1000)
    def test_scope_blocks_other_requests_and_second_credential(self):
        probe=Probe()
        for stage,url,body in [('credential',BASE+'/cos/notify',{}),('credential',URL+'x',None),('shelf',BASE+'/shelf/delete',{})]:
            with self.assertRaises(ValueError):probe.request(stage,url,body)
        probe.requests=1
        with self.assertRaises(ValueError):probe.request('credential',URL)
    def test_default_never_loads_credentials(self):
        with patch('verify_personal_upload_preflight.SessionStore') as store,contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(main([]),0);store.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')


if __name__=='__main__':unittest.main()
