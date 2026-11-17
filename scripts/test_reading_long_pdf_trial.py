"""A fixed text-rich PDF has its own immutable, no-replay scope."""
import hashlib,unittest
from reading_long_pdf_trial import BODY_SHA256_LONG,BODY_SIZE,Journal,MappingJournal,SERVICE,check,prepare,validate_long
from reading_pdf_trial import SERVICE as PDF_SERVICE
from synthetic_pdf_trial import validate_pdf
from synthetic_upload_pdf import build_reading
from synthetic_format_trial import TargetReceipt
from test_native_shelf_trial import source
from test_personal_upload_trial import FakeProbe
from test_secure_native_session import Backend,credentials
from verify_synthetic_epub_upload import run


class LongPDFTrialTest(unittest.TestCase):
    def test_fixed_fixture_and_distinct_scope(self):
        body=build_reading();self.assertEqual((len(body),hashlib.sha256(body).hexdigest()),(BODY_SIZE,BODY_SHA256_LONG))
        self.assertNotEqual(SERVICE,PDF_SERVICE)
        plan=prepare(credentials(),source(),'KOReaderSynthetic-0123456789abcdef.pdf')
        self.assertTrue(check(plan,credentials(),source()))
        with self.assertRaises(ValueError):validate_pdf(plan)
        with self.assertRaises(ValueError):validate_long(dict(plan,body_sha256='0'*64))

    def test_unverified_reader_cleans_exact_fixture_and_never_replays(self):
        journal=Journal(Backend());probe=FakeProbe()
        options=dict(apply=True,sleep=lambda _:None,now=lambda:1000,fixture_builder=build_reading,
            prepare_plan=prepare,check_plan=check,fixture_extension='pdf',readback_tries=9)
        report=run(probe,journal,credentials(),lambda _:True,lambda _:False,**options)
        self.assertEqual(report['result'],'PDF_IMPORTED_SOURCE_UNVERIFIED');self.assertEqual(tuple(probe.attempts.values()),(1,1,1,1))
        self.assertEqual(journal.read()[0]['phase'],'restored')
        self.assertEqual(run(probe,journal,credentials(),lambda _:True,lambda _:True,**options)['reason'],'synthetic_epub/already_reserved')
        self.assertEqual(tuple(probe.attempts.values()),(1,1,1,1))

    def test_mapping_has_distinct_no_replay_scope_and_target_receipt(self):
        journal=MappingJournal(Backend());target=TargetReceipt('pdf',Backend(),scope='pdf-mapping');probe=FakeProbe()
        report=run(probe,journal,credentials(),lambda _:True,lambda _:True,apply=True,sleep=lambda _:None,now=lambda:1000,
            fixture_builder=build_reading,prepare_plan=prepare,check_plan=check,fixture_extension='pdf',readback_tries=9,notify_receipt=target.record)
        self.assertEqual(report['result'],'PDF_IMPORT_AND_SOURCE_VERIFIED');self.assertEqual(tuple(probe.attempts.values()),(1,1,1,1))
        self.assertEqual(journal.read()[0]['phase'],'restored');self.assertIsNotNone(target.backend.load())


if __name__=='__main__':unittest.main()
