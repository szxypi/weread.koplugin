"""The PDF upload trial accepts only a fixed fixture and stops on ambiguity."""
import hashlib,unittest
from personal_upload_trial import SERVICE as TXT_SERVICE
from synthetic_epub_trial import SERVICE as EPUB_SERVICE,validate_epub
from synthetic_pdf_trial import BODY_SHA256,BODY_SIZE,Journal,SERVICE,check,prepare,validate_pdf
from synthetic_upload_pdf import build
from test_native_shelf_trial import source
from test_personal_upload_trial import FakeProbe
from test_secure_native_session import Backend,credentials
from verify_synthetic_epub_upload import run

NAME='KOReaderSynthetic-0123456789abcdef.pdf'


class SyntheticPdfTrialTest(unittest.TestCase):
    def test_fixed_bytes_and_distinct_scope(self):
        body=build();self.assertEqual((len(body),hashlib.sha256(body).hexdigest()),(BODY_SIZE,BODY_SHA256))
        self.assertNotIn(SERVICE,(TXT_SERVICE,EPUB_SERVICE))
        plan=prepare(credentials(),source(),NAME);self.assertTrue(check(plan,credentials(),source()))
        with self.assertRaises(ValueError):validate_epub(plan)
        for bad in (dict(plan,name='private.pdf'),dict(plan,name=NAME+'.epub'),dict(plan,body_sha256='0'*64),dict(plan,extra=True)):
            with self.subTest(bad=bad),self.assertRaises(ValueError):validate_pdf(bad)

    def test_verified_and_unverified_source_both_cleanup_only_the_new_item(self):
        for verified in (False,True):
            probe=FakeProbe();journal=Journal(Backend())
            report=run(probe,journal,credentials(),lambda _:True,lambda _:verified,apply=True,sleep=lambda _:None,now=lambda:1000,
                fixture_builder=build,prepare_plan=prepare,check_plan=check,fixture_extension='pdf')
            self.assertEqual(report['result'],'PDF_IMPORT_AND_SOURCE_VERIFIED' if verified else 'PDF_IMPORTED_SOURCE_UNVERIFIED')
            self.assertEqual(tuple(probe.attempts.values()),(1,1,1,1));self.assertEqual(journal.read()[0]['phase'],'restored')
            again=run(probe,journal,credentials(),lambda _:True,lambda _:True,apply=True,sleep=lambda _:None,now=lambda:1000,
                fixture_builder=build,prepare_plan=prepare,check_plan=check,fixture_extension='pdf')
            self.assertEqual(again['reason'],'synthetic_epub/already_reserved');self.assertEqual(tuple(probe.attempts.values()),(1,1,1,1))

    def test_ambiguous_receipts_do_not_trigger_the_next_write(self):
        for mode,counts in (('put_lost',(1,1,0,0)),('notify_lost',(1,1,1,0)),('foreign_change',(1,1,1,0))):
            probe=FakeProbe(mode);journal=Journal(Backend())
            result=run(probe,journal,credentials(),lambda _:True,lambda _:True,apply=True,sleep=lambda _:None,now=lambda:1000,
                fixture_builder=build,prepare_plan=prepare,check_plan=check,fixture_extension='pdf')
            with self.subTest(mode=mode):
                self.assertEqual(result['result'],'UNVERIFIED');self.assertEqual(tuple(probe.attempts.values()),counts)


if __name__=='__main__':unittest.main()
