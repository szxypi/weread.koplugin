"""Large synthetic fixture, scoped native UI and no-replay boundaries."""
import hashlib,json,unittest
from unittest.mock import patch
from large_epub_trial import BODY_SHA256_LARGE,BODY_SIZE,Journal,SERVICE,check,prepare,validate_large
from native_epub_ui_trial import SERVICE as SMALL_SERVICE,guarded_launch,run
from native_personal_upload_ui_trial import launch
from run_native_personal_upload_ui import validate_input
from secure_weread_session import StoreError
from synthetic_epub_trial import validate_epub
from synthetic_upload_epub import build_large
from test_native_personal_upload_trial import FakeProbe
from test_native_personal_upload_ui_trial import stage
from test_native_shelf_trial import source
from test_secure_native_session import Backend,credentials

NAME='KOReaderSynthetic-0123456789abcdef.epub'


class LargeEpubTrialTest(unittest.TestCase):
    def test_fixed_large_fixture_and_shelf_projection(self):
        body=build_large();self.assertEqual(len(body),BODY_SIZE);self.assertGreater(len(body),8*1024*1024)
        self.assertEqual(hashlib.sha256(body).hexdigest(),BODY_SHA256_LARGE)
        plan=prepare(credentials(),source(),NAME);self.assertTrue(check(plan,credentials(),source()))
        with self.assertRaises(ValueError):validate_epub(plan)
        with self.assertRaises(ValueError):validate_large(dict(plan,body_sha256='0'*64))
    def test_separate_journal_and_generic_runner_reject_replay(self):
        self.assertNotEqual(SERVICE,SMALL_SERVICE);probe=FakeProbe();journal=Journal(Backend())
        result=run(probe,journal,credentials(),lambda _:True,lambda _:True,probe.spawn,apply=True,sleep=lambda _:None,prepare_plan=prepare,check_plan=check)
        self.assertEqual(result['result'],'NATIVE_EPUB_UI_AND_SOURCE_VERIFIED');self.assertEqual((probe.spawns,probe.cleanups),(1,1))
        with self.assertRaises(StoreError):journal.reserve(prepare(credentials(),source(),NAME))
    def test_supervisor_builds_only_fixed_fixture_in_tmpfs(self):
        value=dict(credentials=credentials(),name=NAME,shelf_books=3,rpc_token='a'*32,permit_writes=False,fixture='large_epub')
        validate_input(value,False,None)
        for bad in (dict(value,name='private.epub'),dict(value,body_base64='anything'),dict(value,fixture='other')):
            with self.subTest(bad=bad),self.assertRaises(ValueError):validate_input(bad,False,None)
    def test_private_pipe_selects_fixed_fixture_and_same_plan_preview(self):
        plan=prepare(credentials(),source(),NAME);events=[]
        def child(_plan,_grant,*,armed,fixture):
            self.assertEqual((_plan,fixture),(plan,'large_epub'));events.append('armed' if armed else 'preview')
            return {'target':'CB_synthetic'} if armed else {'preview':True}
        with patch('native_epub_ui_trial.launch',side_effect=child):
            self.assertEqual(guarded_launch(plan,credentials(),lambda *_:events.append('fresh') or True,fixture='large_epub'),{'target':'CB_synthetic'})
        self.assertEqual(events,['preview','fresh','armed'])
        def fake(args,**kwargs):
            self.assertNotIn(credentials()['accessToken'],' '.join(args));length,raw=kwargs['input'].split(b'\n',1)
            self.assertEqual(int(length),len(raw));payload=json.loads(raw);self.assertEqual(payload['fixture'],'large_epub');self.assertNotIn('body_base64',payload)
            value=dict(result='PASS',profile_removed=True,installed=dict(files=300,bytes_match=True),stage=stage(True))
            class Completed:returncode=0;stderr=b'';stdout=('WEREAD_NATIVE_THOUGHT_'+payload['rpc_token']+'_RESULT='+json.dumps(value)+'\n').encode()
            return Completed()
        with patch('native_personal_upload_ui_trial.subprocess.run',side_effect=fake):
            self.assertEqual(launch(plan,credentials(),armed=True,fixture='large_epub')['target'],'CB_synthetic')


if __name__=='__main__':unittest.main()
