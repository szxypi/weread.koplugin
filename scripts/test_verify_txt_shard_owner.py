import contextlib
import io
import json
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from mock_weread import shards
from verify_txt_shard_owner import main


TEXT='A private synthetic first line that remains solely within the captured input.\nAnother line completes this fixture.\n'
RESULT={'result':'PASS','complete_source_matches':True,'second_shard_failure_rejected':True,'partial_source_not_cached':True}
MARKER=b'\nWEREAD_TXT_SHARD_RESULT='


class Session:
    def load(self):return {'vid':'900000','cookies':{'wr_vid':'900000','wr_skey':'mock_key'}}


class Probe:
    def set_cookie(self,*_args):pass
    def verify_account(self):pass
    def find_sample(self,limit):
        assert limit==8
        self.sample={'plain':TEXT,'shards':shards(TEXT,2)}
        return True
    def close(self):pass


class TxtShardOwnerTests(unittest.TestCase):
    def test_default_never_opens_session(self):
        with patch('verify_txt_shard_owner.SessionStore',side_effect=AssertionError('opened')):
            with contextlib.redirect_stdout(io.StringIO()) as output:self.assertEqual(main([]),0)
        self.assertEqual(json.loads(output.getvalue())['result'],'OFFLINE_ONLY')

    def call(self,response):
        child=SimpleNamespace(returncode=0,stdout=MARKER+json.dumps(response).encode(),stderr=b'private diagnostics')
        with patch('verify_txt_shard_owner.SessionStore',Session),patch('verify_txt_shard_owner.TxtProbe',Probe),\
             patch('verify_txt_shard_owner.save_refreshed_web_session'),patch('verify_txt_shard_owner.subprocess.run',return_value=child) as run:
            with contextlib.redirect_stdout(io.StringIO()) as output:
                code=main(['--saved-session','--lua-command','synthetic'])
        self.assertNotIn(TEXT,output.getvalue());self.assertNotIn('mock_key',output.getvalue())
        return code,json.loads(output.getvalue()),run

    def test_complete_real_shape_and_fault_must_both_be_verified(self):
        code,report,run=self.call(RESULT)
        self.assertEqual(code,0);self.assertEqual(report['result'],'REAL_TXT_SHARDS_VERIFIED')
        self.assertEqual(run.call_count,1);self.assertTrue(report['lua_failure_rejected_without_cache'])
        for key,value in (('complete_source_matches',1),('second_shard_failure_rejected',False),('partial_source_not_cached',False)):
            bad=dict(RESULT);bad[key]=value
            code,report,_run=self.call(bad)
            self.assertEqual(code,1);self.assertEqual(report['result'],'UNVERIFIED')


if __name__=='__main__':unittest.main()
