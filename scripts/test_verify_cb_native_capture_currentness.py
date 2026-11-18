"""No account mutations and exact baseline binding for saved CB captures."""
from contextlib import redirect_stdout
from copy import deepcopy
import io,json,unittest
from unittest.mock import Mock,patch

from secure_highlight_trial import Receipt
from test_cb_native_time_capture import fixture
from txt_full_summary import digest
import verify_cb_native_capture_currentness as task


class CurrentnessTests(unittest.TestCase):
    def test_default_is_offline(self):
        with patch.object(task,'SessionStore') as session,redirect_stdout(io.StringIO()) as out:self.assertEqual(task.main([]),0)
        session.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')

    def test_exact_baseline_and_saved_capture_are_required(self):
        for mode in ('success','position_changed','capture_changed','wrong_owner','device_changed','chapter_mismatch'):
            with self.subTest(mode=mode):self.run_case(mode)

    def run_case(self,mode):
        plan,proof,_,_,_=fixture();owner=plan['owner'];book=plan['book_id']
        credentials=dict(vid=owner,deviceId='synthetic-device',accessToken='synthetic-access')
        plan['device_sha256']=digest(credentials['deviceId'])
        baseline=dict(source=plan['raw_sha256'],version=plan['book_version'],native={'chapter_idx':plan['chapter_idx']},point='synthetic-point')
        plan['baseline_sha256']=digest(baseline)
        if mode=='chapter_mismatch':plan['chapter_idx']+=1
        captured=dict(plan=plan,evidence=proof);receipt=Receipt(b'synthetic')
        bundle=Mock();bundle.read.side_effect=[(captured,receipt),(captured,None) if mode=='capture_changed' else (captured,receipt)]
        session=Mock();session.load.return_value=dict(vid='900001' if mode=='wrong_owner' else owner,
            cookies={'wr_vid':owner,'wr_skey':'fixture-secret-cookie'})
        native=Mock();native.load.side_effect=lambda _owner:dict(credentials,deviceId='changed' if mode=='device_changed' else credentials['deviceId'])
        class Web:
            def __init__(self):self.samples=[];self.progress={};self.catalogs=[];self.authenticated=False
            def set_cookie(self,*_args):pass
            def verify_account(self):pass
            def request(self,*_args):return {}
            def inspect(self,_book):return dict(chapter_uid=plan['chapter_uid'])
            def close(self):pass
        observed=deepcopy(baseline)
        if mode=='position_changed':observed['point']='changed'
        with patch.object(task,'CaptureWeb',Web),patch.object(task,'Native'),patch.object(task,'snapshot',return_value=observed),\
             patch.object(task,'save_refreshed_web_session',return_value=False):
            result=task.run(session,native,bundle)
        self.assertEqual(result['result'],'CB_CAPTURE_CURRENT' if mode=='success' else 'UNVERIFIED')
        if mode=='success':self.assertTrue(result['chapter_index_verified'])
        self.assertEqual(result['account_data_posts'],0);self.assertNotIn(book,json.dumps(result));self.assertNotIn('fixture-secret-cookie',json.dumps(result))


if __name__=='__main__':unittest.main()
