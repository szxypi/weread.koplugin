"""No-replay and per-step readback contracts for native subscription UI."""
import unittest
from mp_subscription_trial import SERVICE as PYTHON_SERVICE
from native_mp_subscription_ui_trial import Journal,SERVICE,run
from run_native_mp_subscription_ui import validate_input,validate_stage
from test_mp_subscription_trial import FakeProbe,TARGET
from test_secure_native_session import Backend,credentials

REVIEW=TARGET+'_synthetic'


def stage(armed):
    return dict(result='PASS',phase='complete',permit_writes=armed,chooser=True,preview=True,cancel_no_post=True,
        heartbeat=True,cache_verified=armed,journal_before_posts=armed,local_import_preserved=True,credential_audit=True,guard_selftest=True,
        native_gets=4 if armed else 1,adds=int(armed),removes=int(armed),denied=0,screenshots=0,failed_line=0)


class NativeMPUITest(unittest.TestCase):
    def test_stage_and_input_fail_closed(self):
        for armed in (False,True):
            self.assertEqual(validate_stage(stage(armed),armed),stage(armed))
            for key,value in (('adds',2),('removes',2),('denied',1),('screenshots',1),('local_import_preserved',False),('failed_line',1)):
                bad=stage(armed);bad[key]=value
                with self.subTest(armed=armed,key=key),self.assertRaises(ValueError):validate_stage(bad,armed)
        payload=dict(credentials=credentials(),account_id=TARGET,review_id=REVIEW,shelf_books=3,members_digest='a'*64,rpc_token='b'*32,permit_writes=False)
        validate_input(payload,False,None)
        for bad in (dict(payload,account_id='42'),dict(payload,review_id='MP_WXS_99998_other'),dict(payload,shelf_books=True),dict(payload,members_digest='bad')):
            with self.subTest(bad=bad),self.assertRaises(ValueError):validate_input(bad,False,None)
    def test_roundtrip_requires_independent_confirmation_and_cannot_replay(self):
        self.assertNotEqual(SERVICE,PYTHON_SERVICE);probe=FakeProbe();journal=Journal(Backend());events=[]
        def runner(_plan,_grant,_review,armed,step):
            events.append('armed' if armed else 'preview')
            if armed:
                probe.state['books'].append(dict(bookId=TARGET,title='Synthetic',finishReading=0));step(1);events.append('confirmed_add')
                probe.state['books']=[row for row in probe.state['books'] if row['bookId']!=TARGET];step(2);events.append('confirmed_remove')
            return stage(armed)
        result=run(probe,journal,credentials(),TARGET,REVIEW,lambda _:True,runner,apply=True)
        self.assertEqual(result['result'],'NATIVE_MP_UI_ROUNDTRIP_VERIFIED');self.assertEqual(events,['preview','armed','confirmed_add','confirmed_remove'])
        self.assertEqual(result['independent_steps'],2);self.assertEqual(journal.read()[0]['phase'],'restored')
        self.assertEqual(run(probe,journal,credentials(),TARGET,REVIEW,lambda _:True,runner,apply=True)['reason'],'native_mp_ui/already_reserved')
        self.assertEqual(len(events),4)
    def test_unknown_or_foreign_change_stops_without_authorizing_next_step(self):
        for mode,expected_phase,steps in (('before_add','add_pending',0),('foreign_add','add_pending',0),('after_add','remove_pending',1),('foreign_remove','remove_pending',1)):
            with self.subTest(mode=mode):
                probe=FakeProbe();journal=Journal(Backend())
                def runner(_plan,_grant,_review,armed,step):
                    if not armed:return stage(False)
                    if mode=='before_add':raise TimeoutError()
                    probe.state['books'].append(dict(bookId=TARGET,title='Synthetic',finishReading=0))
                    if mode=='foreign_add':probe.state['books'][0]['secret']=1
                    step(1)
                    if mode=='after_add':raise TimeoutError()
                    probe.state['books']=[row for row in probe.state['books'] if row['bookId']!=TARGET]
                    probe.state['books'][0]['secret']=1;step(2);return stage(True)
                result=run(probe,journal,credentials(),TARGET,REVIEW,lambda _:True,runner,apply=True)
                self.assertEqual(result['result'],'UNVERIFIED');self.assertEqual(result['independent_steps'],steps)
                self.assertEqual(journal.read()[0]['phase'],expected_phase)
    def test_preview_never_creates_intent_and_mismatched_grant_stops(self):
        probe=FakeProbe();journal=Journal(Backend());calls=[]
        def runner(_plan,_grant,_review,armed,_step):calls.append(armed);return stage(armed)
        result=run(probe,journal,credentials(),TARGET,REVIEW,lambda _:True,runner)
        self.assertEqual(result['result'],'READ_ONLY_PREVIEW');self.assertEqual(calls,[False]);self.assertIsNone(journal.read()[0])
        calls.clear();result=run(probe,journal,credentials(),TARGET,REVIEW,lambda _:False,runner,apply=True)
        self.assertEqual(result['reason'],'native_mp_ui/grant');self.assertEqual(calls,[])


if __name__=='__main__':unittest.main()
