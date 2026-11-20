"""EPUB trial accepts only the fixed self-authored bytes and a fresh scope."""
from copy import deepcopy
import hashlib,unittest
from personal_upload_trial import SERVICE as TXT_SERVICE,validate as validate_txt
from secure_weread_session import StoreError
from synthetic_epub_trial import BODY_SHA256,Journal,SERVICE,check,prepare,validate_epub
from synthetic_upload_epub import build
from test_native_shelf_trial import source
from test_secure_native_session import Backend,credentials

NAME='KOReaderSynthetic-0123456789abcdef.epub'


class SyntheticEpubTrialTest(unittest.TestCase):
    def test_only_fixed_fixture_and_safe_new_name_are_accepted(self):
        plan=prepare(credentials(),source(),NAME)
        self.assertEqual(hashlib.sha256(build()).hexdigest(),BODY_SHA256);self.assertEqual(plan['body_sha256'],BODY_SHA256)
        with self.assertRaises(ValueError):validate_txt(plan)
        for bad in (dict(plan,name='private.epub'),dict(plan,name=NAME+'.txt'),dict(plan,body_sha256='0'*64),dict(plan,extra=True)):
            with self.subTest(bad=bad),self.assertRaises(ValueError):validate_epub(bad)
    def test_exact_new_item_and_unchanged_other_shelf_fields(self):
        plan=prepare(credentials(),source(),NAME);value=source();self.assertTrue(check(plan,credentials(),value))
        value['books'].append(dict(bookId='CB_synthetic',title='Synthetic',finishReading=0))
        self.assertTrue(check(plan,credentials(),value,'CB_synthetic',True))
        changed=deepcopy(value);changed['books'][0]['secret']=1
        with self.assertRaises(ValueError):check(plan,credentials(),changed,'CB_synthetic',True)
    def test_separate_durable_journal_cannot_replay_or_change_fixture(self):
        self.assertNotEqual(SERVICE,TXT_SERVICE);journal=Journal(Backend());plan=prepare(credentials(),source(),NAME)
        receipt=journal.reserve(plan)
        with self.assertRaises(StoreError):journal.reserve(plan)
        receipt=journal.advance(receipt,'credential_pending')
        receipt=journal.advance(receipt,'credential_ready',object_sha256='a'*64)
        for phase in ('upload_pending','uploaded','notify_pending'):receipt=journal.advance(receipt,phase)
        receipt=journal.advance(receipt,'imported',target='CB_synthetic')
        for phase in ('cleanup_pending','restored'):receipt=journal.advance(receipt,phase)
        self.assertEqual(journal.read()[0]['phase'],'restored')
        with self.assertRaises(StoreError):journal.reserve(plan)


if __name__=='__main__':unittest.main()
