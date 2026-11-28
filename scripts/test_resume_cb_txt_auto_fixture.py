import unittest

from cb_initial_fixture_intent import Intent
from personal_upload_trial import hash_value
from resume_cb_txt_auto_fixture import fixture_authorized, resume_upload
from secure_shelf_experiment import canonical
from test_cb_fixture_position_transport import MemoryBackend
from test_personal_upload_trial import FakeProbe, NAME, TARGET, source
from test_secure_native_session import credentials
from verify_cb_initial_fixture_ui_trial import resume_reservation
from verify_cb_txt_fixture import Journal, prepare_plan


class ResumeTest(unittest.TestCase):
    def fixture(self,mode='normal'):
        grant=credentials();journal=Journal(backend=MemoryBackend());plan=prepare_plan(grant,source(),NAME)
        token=journal.reserve(plan)
        for phase in ('credential_pending','credential_ready','upload_pending','uploaded','notify_pending'):
            token=journal.advance(token,phase,**({'object_sha256':'a'*64} if phase=='credential_ready' else {}))
        token=journal.advance(token,'imported',target=TARGET);state,_=journal.read()
        receipt=MemoryBackend();receipt.save(canonical(dict(schema=1,owner=grant['vid'],attempt=state['attempt'],
            target=TARGET,plan_sha256=hash_value(plan))))
        probe=FakeProbe(mode);probe.state['books'].append(dict(bookId=TARGET,title='Synthetic',finishReading=0))
        return grant,journal,receipt,probe

    def test_unclaimed_reservation_bound_to_exact_source_and_identity(self):
        intent=Intent(backend=MemoryBackend());intent.reserve('900000','CB_fixture','a'*32,'b'*64)
        self.assertEqual(resume_reservation(intent,'900000','CB_fixture','a'*32,'b'*64)['claimed'],0)
        with self.assertRaises(ValueError):resume_reservation(intent,'900000','CB_fixture','a'*32,'c'*64)
        state=resume_reservation(intent,'900000','CB_fixture','a'*32,'b'*64);intent.claim(state,'write_enter')
        with self.assertRaises(ValueError):resume_reservation(intent,'900000','CB_fixture','a'*32,'b'*64)

    def test_owned_fixture_is_cleaned_once_after_completed_gate(self):
        grant,journal,receipt,probe=self.fixture();gate=[]
        result=resume_upload(probe,journal,grant,lambda _:True,lambda target:target==TARGET,apply=True,
            cleanup_gate=lambda *_:gate.append(True) or True,receipt_backend=receipt,notes=lambda _:True,sleep=lambda _:None)
        self.assertEqual(result['result'],'TXT_IMPORT_AND_SOURCE_VERIFIED');self.assertEqual(gate,[True])
        self.assertEqual(result['cleanup_posts'],1);self.assertEqual(journal.read()[0]['phase'],'restored')
        self.assertEqual(probe.attempts['notify'],0);self.assertEqual(probe.attempts['cleanup'],1)
        again=resume_upload(probe,journal,grant,lambda _:True,lambda _:True,apply=True,
            cleanup_gate=lambda *_:True,receipt_backend=receipt,notes=lambda _:True,sleep=lambda _:None)
        self.assertEqual(again['result'],'UNVERIFIED');self.assertEqual(probe.attempts['cleanup'],1)

    def test_unknown_or_changed_state_never_replays_cleanup(self):
        for mode in ('cleanup_lost','grouped','notes','unfinished'):
            grant,journal,receipt,probe=self.fixture('cleanup_lost' if mode=='cleanup_lost' else 'normal')
            if mode=='grouped':probe.state['archive'][0]['bookIds'].append(TARGET)
            result=resume_upload(probe,journal,grant,lambda _:True,lambda _:True,apply=True,
                cleanup_gate=lambda *_:mode!='unfinished',receipt_backend=receipt,notes=lambda _:mode!='notes',sleep=lambda _:None)
            self.assertEqual(result['result'],'UNVERIFIED')
            self.assertEqual(probe.attempts['cleanup'],1 if mode=='cleanup_lost' else 0)
            if mode=='cleanup_lost':
                self.assertEqual(journal.read()[0]['phase'],'cleanup_pending')
                resume_upload(probe,journal,grant,lambda _:True,lambda _:True,apply=True,
                    cleanup_gate=lambda *_:True,receipt_backend=receipt,notes=lambda _:True,sleep=lambda _:None)
                self.assertEqual(probe.attempts['cleanup'],1)

    def test_receipt_must_match_exact_target_and_journal(self):
        grant,journal,receipt,_probe=self.fixture();state,token=journal.read()
        self.assertTrue(fixture_authorized(receipt,journal,token,TARGET,grant['vid']))
        self.assertFalse(fixture_authorized(receipt,journal,token,'CB_other',grant['vid']))
        receipt.save(b'{}')
        self.assertFalse(fixture_authorized(receipt,journal,token,TARGET,grant['vid']))


if __name__=='__main__':unittest.main()
