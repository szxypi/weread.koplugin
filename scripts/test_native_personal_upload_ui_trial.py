"""Offline scope and evidence validation for the owner upload UI trial."""
from copy import deepcopy
import json,unittest
from unittest.mock import patch
from native_personal_upload_ui_trial import Journal,SERVICE,guarded_launch,launch
from native_personal_upload_trial import SERVICE as EXECUTOR_SERVICE
from personal_upload_trial import prepare
from run_native_personal_upload_ui import validate_input,validate_stage
from secure_weread_session import StoreError
from test_native_shelf_trial import source
from test_secure_native_session import Backend,credentials

NAME='KOReaderSynthetic-0123456789abcdef.txt'


def stage(armed):
    value=dict(result='PASS',phase='complete',permit_writes=armed,chooser=True,cancel_no_request=True,
        heartbeat=armed,journal_idle=armed,cache_verified=armed,file_unchanged=True,credential_audit=True,guard_selftest=True,
        native_gets=2 if armed else 0,credential_gets=int(armed),puts=int(armed),notifies=int(armed),denied=0,screenshots=0,failed_line=0)
    if armed:value['target']='CB_synthetic'
    return value


class UITrialTest(unittest.TestCase):
    def test_stage_accepts_only_complete_bounded_evidence(self):
        for armed in (False,True):
            self.assertEqual(validate_stage(stage(armed),armed),stage(armed))
            for field,value in (('denied',1),('screenshots',1),('file_unchanged',False),('credential_gets',2),('failed_line',2)):
                bad=stage(armed);bad[field]=value
                with self.subTest(armed=armed,field=field),self.assertRaises(ValueError):validate_stage(bad,armed)
        bad=stage(False);bad['native_gets']=1
        with self.assertRaises(ValueError):validate_stage(bad,False)
        bad=stage(True);bad.pop('target')
        with self.assertRaises(ValueError):validate_stage(bad,True)
    def test_owner_and_mock_payloads_cannot_be_mixed(self):
        payload=dict(credentials=credentials(),name=NAME,shelf_books=3,rpc_token='a'*32,permit_writes=False)
        validate_input(payload,False,None)
        for bad in (dict(payload,name='other.txt'),dict(payload,shelf_books=True),dict(payload,permit_writes=True),dict(payload,mock_port=123)):
            with self.subTest(bad=bad),self.assertRaises(ValueError):validate_input(bad,False,None)
        mixed=dict(payload,mock_port=123)
        with self.assertRaises(ValueError):validate_input(mixed,False,123)
    def test_journal_has_distinct_permanent_no_replay_scope(self):
        self.assertNotEqual(SERVICE,EXECUTOR_SERVICE)
        journal=Journal(Backend());plan=prepare(credentials(),source(),NAME,b'synthetic')
        receipt=journal.reserve(plan)
        with self.assertRaises(StoreError):journal.reserve(plan)
        for phase in ('launched','imported','cleanup_pending','restored'):
            receipt=journal.advance(receipt,phase,**({'target':'CB_synthetic'} if phase=='imported' else {}))
        with self.assertRaises(StoreError):journal.reserve(plan)
    def test_supervisor_result_is_strict_and_credentials_use_stdin(self):
        plan=prepare(credentials(),source(),NAME,b'Synthetic upload for KOReader.\n')
        class Completed:
            returncode=0;stderr=b''
            def __init__(self,value):self.value=value
        def fake_run(args,**kwargs):
            self.assertNotIn(credentials()['accessToken'],' '.join(args))
            raw=kwargs['input'];length,body=raw.split(b'\n',1);self.assertEqual(int(length),len(body));payload=json.loads(body)
            selected=deepcopy(current[0]);prefix=('WEREAD_NATIVE_THOUGHT_'+payload['rpc_token']+'_RESULT=').encode()
            selected.stdout=prefix+json.dumps(selected.value).encode()+b'\n';return selected
        base=dict(result='PASS',profile_removed=True,installed=dict(files=300,bytes_match=True),stage=stage(True))
        for mode in ('valid','not_removed','wrong_package','invalid_count'):
            value=deepcopy(base)
            if mode=='not_removed':value['profile_removed']=False
            elif mode=='wrong_package':value['installed']['bytes_match']=False
            elif mode=='invalid_count':value['stage']['puts']=2
            current=[Completed(value)]
            with self.subTest(mode=mode),patch('native_personal_upload_ui_trial.subprocess.run',side_effect=fake_run):
                if mode=='valid':self.assertEqual(launch(plan,credentials(),armed=True)['target'],'CB_synthetic')
                else:
                    with self.assertRaises(ValueError):launch(plan,credentials(),armed=True)
        with self.assertRaises(ValueError):launch(plan,dict(credentials(),accessToken='other-access-token'),armed=True)
    def test_exact_plan_preview_and_fresh_read_precede_armed_execution(self):
        plan=prepare(credentials(),source(),NAME,b'Synthetic upload for KOReader.\n');events=[]
        def child(_plan,_grant,*,armed):
            self.assertEqual(_plan,plan);events.append('armed' if armed else 'preview')
            return {'target':'CB_synthetic'} if armed else {'preview':True}
        def fresh(_plan,_grant):self.assertEqual(_plan,plan);events.append('fresh');return True
        with patch('native_personal_upload_ui_trial.launch',side_effect=child):
            self.assertEqual(guarded_launch(plan,credentials(),fresh),{'target':'CB_synthetic'})
        self.assertEqual(events,['preview','fresh','armed'])
        events.clear()
        with patch('native_personal_upload_ui_trial.launch',side_effect=child),self.assertRaises(ValueError):
            guarded_launch(plan,credentials(),lambda *_args:False)
        self.assertEqual(events,['preview'])


if __name__=='__main__':unittest.main()
