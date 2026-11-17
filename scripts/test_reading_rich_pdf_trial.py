"""Guard a unique rich PDF test fixture and its exact one-shot cleanup."""
import hashlib,unittest
from reading_rich_pdf_trial import BODY_SHA256_RICH,BODY_SIZE,Journal,check,prepare,validate_rich
from synthetic_format_trial import TargetReceipt
from synthetic_upload_rich_pdf import build
from test_native_shelf_trial import source
from test_personal_upload_trial import FakeProbe
from test_secure_native_session import Backend,credentials
from verify_synthetic_epub_upload import run


class RichPDFTrialTest(unittest.TestCase):
    def test_fixed_fixture_and_plan(self):
        self.assertEqual((len(build()),hashlib.sha256(build()).hexdigest()),(BODY_SIZE,BODY_SHA256_RICH))
        plan=prepare(credentials(),source(),'KOReaderSynthetic-0123456789abcdef.pdf')
        self.assertTrue(check(plan,credentials(),source()))
        with self.assertRaises(ValueError):validate_rich(dict(plan,body_sha256='0'*64))
        with self.assertRaises(ValueError):TargetReceipt('epub',Backend(),scope='rich-pdf')

    def test_exact_target_and_no_replay_even_when_conversion_unverified(self):
        journal=Journal(Backend());target=TargetReceipt('pdf',Backend(),scope='rich-pdf');probe=FakeProbe()
        options=dict(apply=True,sleep=lambda _:None,now=lambda:1000,fixture_builder=build,
            prepare_plan=prepare,check_plan=check,fixture_extension='pdf',readback_tries=9,notify_receipt=target.record)
        result=run(probe,journal,credentials(),lambda _:True,lambda _:False,**options)
        self.assertEqual(result['result'],'PDF_IMPORTED_SOURCE_UNVERIFIED')
        self.assertEqual(tuple(probe.attempts.values()),(1,1,1,1))
        self.assertEqual(journal.read()[0]['phase'],'restored');self.assertIsNotNone(target.backend.load())
        self.assertEqual(run(probe,journal,credentials(),lambda _:True,lambda _:True,**options)['reason'],'synthetic_epub/already_reserved')
        self.assertEqual(tuple(probe.attempts.values()),(1,1,1,1))


if __name__=='__main__':unittest.main()
