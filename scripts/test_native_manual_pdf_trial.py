"""The real-account manual PDF probe remains read-only and strictly scoped."""
from copy import deepcopy
import base64,json,unittest
from unittest.mock import patch
from native_manual_pdf_trial import launch
from synthetic_upload_rich_pdf import build
from test_native_personal_upload_ui_trial import stage
from test_secure_native_session import credentials


class ManualPDFTrialTest(unittest.TestCase):
    def test_validates_proof_and_sends_private_inputs_only_on_stdin(self):
        proof=stage(False);proof.update(manual_confirmation=True,manual_cancel_safe=True,manual_linked=True,
                                        manual_pdf_pages=True,manual_cloud_unbound=True,manual_unlink_cancel_safe=True,manual_unlinked=True)
        result=dict(result='PASS',profile_removed=True,installed=dict(files=308,bytes_match=True),stage=proof)
        def fake(command,**kwargs):
            self.assertNotIn(credentials()['accessToken'],' '.join(command));self.assertNotIn('CB_synthetic',' '.join(command))
            length,raw=kwargs['input'].split(b'\n',1);self.assertEqual(int(length),len(raw));payload=json.loads(raw)
            self.assertFalse(payload['permit_writes']);self.assertEqual(base64.b64decode(payload['body_base64']),build())
            class Child:returncode=0;stderr=b'';stdout=('WEREAD_NATIVE_THOUGHT_'+payload['rpc_token']+'_RESULT='+json.dumps(result)+'\n').encode()
            return Child()
        with patch('native_manual_pdf_trial.subprocess.run',side_effect=fake):
            observed=launch(credentials(),'CB_synthetic',3,width=600,height=800,dpi=167)
        self.assertEqual(observed['result'],'MANUAL_LOCAL_PDF_NATIVE_VERIFIED');self.assertEqual(observed['network_requests'],0)
        for key in ('manual_linked','manual_cloud_unbound','manual_unlink_cancel_safe','manual_unlinked'):
            bad=deepcopy(result);bad['stage'][key]=False
            def rejected(command,**kwargs):
                _,raw=kwargs['input'].split(b'\n',1);payload=json.loads(raw)
                class Child:returncode=0;stderr=b'';stdout=('WEREAD_NATIVE_THOUGHT_'+payload['rpc_token']+'_RESULT='+json.dumps(bad)+'\n').encode()
                return Child()
            with self.subTest(key=key),patch('native_manual_pdf_trial.subprocess.run',side_effect=rejected),self.assertRaises(ValueError):
                launch(credentials(),'CB_synthetic',3,width=600,height=800,dpi=167)

    def test_rejects_unscoped_identity_or_dimensions(self):
        for target,width in (('42',600),('CB_bad/other',600),('CB_synthetic',601)):
            with self.subTest(target=target,width=width),self.assertRaises(ValueError):
                launch(credentials(),target,3,width=width,height=800,dpi=167)


if __name__=='__main__':unittest.main()
