"""Fixed EPUB reading trial keeps independent scope and safe cleanup."""
import hashlib,unittest
from reading_epub_trial import BODY_SHA256_READING,BODY_SIZE,Journal,SERVICE,check,prepare,validate_reading
from synthetic_epub_trial import SERVICE as SMALL_SERVICE,validate_epub
from synthetic_upload_epub import build_reading
from test_native_shelf_trial import source
from test_personal_upload_trial import FakeProbe
from test_secure_native_session import Backend,credentials
from verify_synthetic_epub_upload import run

NAME='KOReaderSynthetic-0123456789abcdef.epub'


class ReadingEpubTrialTest(unittest.TestCase):
    def test_exact_fixture_and_distinct_scope(self):
        body=build_reading();self.assertEqual((len(body),hashlib.sha256(body).hexdigest()),(BODY_SIZE,BODY_SHA256_READING))
        self.assertNotEqual(SERVICE,SMALL_SERVICE);plan=prepare(credentials(),source(),NAME)
        self.assertTrue(check(plan,credentials(),source()))
        with self.assertRaises(ValueError):validate_epub(plan)
        with self.assertRaises(ValueError):validate_reading(dict(plan,body_sha256='0'*64))
    def test_native_reader_failure_does_not_repeat_or_leave_proven_item(self):
        probe=FakeProbe();journal=Journal(Backend())
        report=run(probe,journal,credentials(),lambda _:True,lambda _:False,apply=True,sleep=lambda _:None,now=lambda:1000,
            fixture_builder=build_reading,prepare_plan=prepare,check_plan=check)
        self.assertEqual(report['result'],'EPUB_IMPORTED_SOURCE_UNVERIFIED');self.assertEqual(tuple(probe.attempts.values()),(1,1,1,1))
        self.assertEqual(journal.read()[0]['phase'],'restored')
        again=run(probe,journal,credentials(),lambda _:True,lambda _:True,apply=True,sleep=lambda _:None,now=lambda:1000,
            fixture_builder=build_reading,prepare_plan=prepare,check_plan=check)
        self.assertEqual(again['reason'],'synthetic_epub/already_reserved');self.assertEqual(tuple(probe.attempts.values()),(1,1,1,1))


if __name__=='__main__':unittest.main()
