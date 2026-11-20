"""Synthetic checks for the distinct EPUB native UI trial and no replay."""
import base64,json,unittest
from unittest.mock import patch
from native_epub_ui_trial import Journal,SERVICE,guarded_launch,run
from native_personal_upload_ui_trial import SERVICE as TXT_SERVICE
from native_personal_upload_ui_trial import launch
from run_native_personal_upload_ui import validate_input
from synthetic_epub_trial import SERVICE as EPUB_SERVICE,prepare
from synthetic_upload_epub import build
from test_native_personal_upload_trial import FakeProbe
from test_native_shelf_trial import source
from test_secure_native_session import Backend,credentials
from test_native_personal_upload_ui_trial import stage


class NativeEpubUITest(unittest.TestCase):
    def test_uses_distinct_durable_scope_and_checks_source_before_cleanup(self):
        self.assertNotIn(SERVICE,(TXT_SERVICE,EPUB_SERVICE));probe=FakeProbe();journal=Journal(Backend());events=[]
        def read(target):events.append(target);return True
        result=run(probe,journal,credentials(),lambda _:True,read,probe.spawn,apply=True,sleep=lambda _:None)
        self.assertEqual(result['result'],'NATIVE_EPUB_UI_AND_SOURCE_VERIFIED');self.assertTrue(result['source_verified'])
        self.assertEqual((probe.spawns,probe.cleanups,len(events)),(1,1,1));self.assertEqual(journal.read()[0]['phase'],'restored')
        result=run(probe,journal,credentials(),lambda _:True,read,probe.spawn,apply=True,sleep=lambda _:None)
        self.assertEqual(result['reason'],'epub_ui/already_reserved');self.assertEqual((probe.spawns,probe.cleanups),(1,1))
    def test_read_failure_cleans_exact_item_but_remains_unverified(self):
        probe=FakeProbe();journal=Journal(Backend())
        result=run(probe,journal,credentials(),lambda _:True,lambda _:False,probe.spawn,apply=True,sleep=lambda _:None)
        self.assertEqual(result['result'],'NATIVE_EPUB_UI_SOURCE_UNVERIFIED');self.assertFalse(result['source_verified'])
        self.assertEqual(probe.cleanups,1);self.assertEqual(journal.read()[0]['phase'],'restored')
    def test_unknown_or_unrelated_changes_stop_before_cleanup(self):
        for mode,phase,counts in (('baseline_changed',None,(0,0)),('child_lost','launched',(1,0)),
                ('existing_target','launched',(1,0)),('foreign_change','launched',(1,0)),('cleanup_lost','cleanup_pending',(1,1))):
            with self.subTest(mode=mode):
                probe=FakeProbe(mode);journal=Journal(Backend())
                result=run(probe,journal,credentials(),lambda _:True,lambda _:True,probe.spawn,apply=True,sleep=lambda _:None)
                self.assertEqual(result['result'],'UNVERIFIED');self.assertEqual((probe.spawns,probe.cleanups),counts)
                state,_=journal.read();self.assertEqual(state['phase'] if state else None,phase)
    def test_exact_epub_plan_preview_and_fresh_check_precede_write(self):
        plan=prepare(credentials(),source(),'KOReaderSynthetic-0123456789abcdef.epub');events=[]
        def child(_plan,_grant,*,armed,fixture):
            self.assertEqual((_plan,fixture),(plan,'epub'));events.append('armed' if armed else 'preview')
            return {'target':'CB_synthetic'} if armed else {'preview':True}
        with patch('native_epub_ui_trial.launch',side_effect=child):
            self.assertEqual(guarded_launch(plan,credentials(),lambda *_:events.append('fresh') or True),{'target':'CB_synthetic'})
        self.assertEqual(events,['preview','fresh','armed']);events.clear()
        with patch('native_epub_ui_trial.launch',side_effect=child),self.assertRaises(ValueError):guarded_launch(plan,credentials(),lambda *_:False)
        self.assertEqual(events,['preview'])
    def test_fixture_and_identity_validation_rejects_arbitrary_data(self):
        value=dict(credentials=credentials(),name='KOReaderSynthetic-0123456789abcdef.epub',shelf_books=3,rpc_token='a'*32,
            permit_writes=False,fixture='epub',body_base64=base64.b64encode(build()).decode('ascii'))
        validate_input(value,False,None)
        for bad in (dict(value,body_base64=base64.b64encode(b'private').decode('ascii')),dict(value,name='private.epub'),
                    dict(value,fixture='txt'),dict(value,name='KOReaderSynthetic-0123456789abcdef.txt')):
            with self.subTest(bad=bad),self.assertRaises(ValueError):validate_input(bad,False,None)
    def test_epub_launch_sends_fixed_bytes_only_through_private_pipe(self):
        plan=prepare(credentials(),source(),'KOReaderSynthetic-0123456789abcdef.epub')
        def fake(args,**kwargs):
            self.assertNotIn(credentials()['accessToken'],' '.join(args))
            length,raw=kwargs['input'].split(b'\n',1);self.assertEqual(int(length),len(raw));payload=json.loads(raw)
            self.assertEqual(base64.b64decode(payload['body_base64']),build());self.assertEqual(payload['fixture'],'epub')
            value=dict(result='PASS',profile_removed=True,installed=dict(files=300,bytes_match=True),stage=stage(True))
            class Completed:returncode=0;stderr=b'';stdout=('WEREAD_NATIVE_THOUGHT_'+payload['rpc_token']+'_RESULT='+json.dumps(value)+'\n').encode()
            return Completed()
        with patch('native_personal_upload_ui_trial.subprocess.run',side_effect=fake):
            self.assertEqual(launch(plan,credentials(),armed=True,fixture='epub')['target'],'CB_synthetic')
        with self.assertRaises(ValueError):launch(plan,credentials(),armed=True,fixture='txt')


if __name__=='__main__':unittest.main()
