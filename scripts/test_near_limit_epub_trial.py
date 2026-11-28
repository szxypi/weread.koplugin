"""Streamed near-limit EPUB fixture and one-shot UI upload boundaries."""
import io,unittest,zipfile
from near_limit_epub_trial import BODY_SHA256_NEAR,BODY_SIZE,Journal,check,prepare,validate_near
from native_epub_ui_trial import run
from run_native_personal_upload_ui import validate_input
from synthetic_epub_trial import validate_epub
from synthetic_format_trial import TargetReceipt
from synthetic_near_limit_epub import _write
from test_native_personal_upload_trial import FakeProbe
from test_native_shelf_trial import source
from test_secure_native_session import Backend,credentials

NAME='KOReaderSynthetic-0123456789abcdef.epub'


class NearLimitTest(unittest.TestCase):
    def test_streamed_container_has_fixed_metadata_and_body(self):
        output=io.BytesIO();_write(output,1024)
        with zipfile.ZipFile(output) as archive:
            self.assertEqual(archive.read('mimetype'),b'application/epub+zip')
            self.assertEqual(archive.read('EPUB/padding.txt'),b'L'*1024)
            self.assertIn(b'padding.txt',archive.read('EPUB/package.opf'))
        self.assertTrue(198*1024*1024<BODY_SIZE<=200*1024*1024)
        with self.assertRaises(ValueError):_write(io.BytesIO(),0)

    def test_scope_and_ui_payload_are_strict(self):
        plan=prepare(credentials(),source(),NAME);self.assertTrue(check(plan,credentials(),source()))
        self.assertEqual(plan['body_sha256'],BODY_SHA256_NEAR)
        with self.assertRaises(ValueError):validate_epub(plan)
        with self.assertRaises(ValueError):validate_near(dict(plan,body_sha256='0'*64))
        payload=dict(credentials=credentials(),name=NAME,shelf_books=3,rpc_token='a'*32,permit_writes=False,fixture='near_epub')
        validate_input(payload,False,None)
        with self.assertRaises(ValueError):validate_input(dict(payload,body_base64='extra'),False,None)

    def test_one_shot_receipt_and_exact_cleanup(self):
        journal=Journal(Backend());target=TargetReceipt('epub',Backend(),scope='near-ui');probe=FakeProbe()
        kwargs=dict(apply=True,sleep=lambda _:None,prepare_plan=prepare,check_plan=check,readback_tries=9,notify_receipt=target.record)
        result=run(probe,journal,credentials(),lambda _:True,lambda _:True,probe.spawn,**kwargs)
        self.assertEqual(result['result'],'NATIVE_EPUB_UI_AND_SOURCE_VERIFIED');self.assertEqual((probe.spawns,probe.cleanups),(1,1))
        self.assertEqual(journal.read()[0]['phase'],'restored');self.assertIsNotNone(target.backend.load())
        again=run(probe,journal,credentials(),lambda _:True,lambda _:True,probe.spawn,**kwargs)
        self.assertEqual(again['reason'],'epub_ui/already_reserved');self.assertEqual((probe.spawns,probe.cleanups),(1,1))

    def test_exact_boundary_uses_its_own_scope_and_fixed_fixture(self):
        from exact_limit_epub_trial import BODY_SHA256_EXACT,BODY_SIZE as EXACT_SIZE,Journal as ExactJournal,JournalV2
        from exact_limit_epub_trial import check as check_exact,prepare as prepare_exact,validate_exact
        from near_limit_epub_trial import SERVICE as NEAR_SERVICE
        from exact_limit_epub_trial import SERVICE as EXACT_SERVICE
        self.assertNotEqual(NEAR_SERVICE,EXACT_SERVICE);self.assertEqual(EXACT_SIZE,200*1024*1024)
        plan=prepare_exact(credentials(),source(),NAME);self.assertEqual(plan['body_sha256'],BODY_SHA256_EXACT)
        self.assertTrue(check_exact(plan,credentials(),source()))
        with self.assertRaises(ValueError):validate_exact(dict(plan,body_sha256=BODY_SHA256_NEAR))
        payload=dict(credentials=credentials(),name=NAME,shelf_books=3,rpc_token='a'*32,permit_writes=False,fixture='exact_epub')
        validate_input(payload,False,None)
        journal=ExactJournal(Backend());target=TargetReceipt('epub',Backend(),scope='exact-ui');probe=FakeProbe()
        result=run(probe,journal,credentials(),lambda _:True,lambda _:True,probe.spawn,apply=True,sleep=lambda _:None,
            prepare_plan=prepare_exact,check_plan=check_exact,readback_tries=9,notify_receipt=target.record)
        self.assertEqual(result['result'],'NATIVE_EPUB_UI_AND_SOURCE_VERIFIED');self.assertEqual((probe.spawns,probe.cleanups),(1,1))
        self.assertEqual(journal.read()[0]['phase'],'restored');self.assertIsNotNone(target.backend.load())
        next_journal=JournalV2(Backend());next_receipt=TargetReceipt('epub',Backend(),scope='exact-ui-v2')
        self.assertIsNone(next_journal.read()[0]);self.assertIsNone(next_receipt.backend.load())
        with self.assertRaises(ValueError):TargetReceipt('mobi',Backend(),scope='exact-ui-v2')


if __name__=='__main__':unittest.main()
