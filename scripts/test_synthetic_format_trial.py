"""Fixed synthetic format boundaries and exact target receipt persistence."""
import json,unittest
from synthetic_format_trial import FORMATS,Journal,TargetReceipt,build,check,prepare,validator
from test_native_shelf_trial import source
from test_personal_upload_trial import FakeProbe
from test_secure_native_session import Backend,credentials
from verify_synthetic_epub_upload import run


class SyntheticFormatTrialTest(unittest.TestCase):
    def run_trial(self,ext,mode='normal'):
        journal=Journal(ext,Backend());target=TargetReceipt(ext,Backend());probe=FakeProbe(mode)
        result=run(probe,journal,credentials(),lambda _:True,lambda _:True,apply=True,sleep=lambda _:None,now=lambda:1000,
            fixture_builder=lambda:build(ext),prepare_plan=lambda grant,shelf,name:prepare(ext,grant,shelf,name),
            check_plan=lambda plan,grant,shelf,target=None,expected=False:check(ext,plan,grant,shelf,target,expected),
            fixture_extension=ext,readback_tries=9,notify_receipt=target.record)
        return result,journal,target,probe

    def test_only_fixed_bytes_and_names_are_accepted(self):
        for ext in FORMATS:
            with self.subTest(ext=ext):
                self.assertEqual(len(build(ext)),FORMATS[ext][0])
                plan=prepare(ext,credentials(),source(),'KOReaderSynthetic-0123456789abcdef.'+ext)
                self.assertTrue(check(ext,plan,credentials(),source()))
                for bad in (dict(plan,name='private.'+ext),dict(plan,body_sha256='0'*64),dict(plan,extra=True)):
                    with self.assertRaises(ValueError):validator(ext)(bad)
        with self.assertRaises(ValueError):build('txt')

    def test_confirmed_identity_is_persisted_before_shelf_visibility(self):
        for ext in FORMATS:
            result,journal,target,probe=self.run_trial(ext)
            self.assertEqual(result['result'],ext.upper()+'_IMPORT_AND_SOURCE_VERIFIED')
            self.assertEqual(journal.read()[0]['phase'],'restored');self.assertIsNotNone(target.backend.load())
            self.assertEqual(tuple(probe.attempts.values()),(1,1,1,1))

    def test_unknown_notify_never_creates_receipt_or_cleans_up(self):
        for ext in FORMATS:
            result,journal,target,probe=self.run_trial(ext,'notify_lost')
            self.assertEqual(result['result'],'UNVERIFIED');self.assertEqual(journal.read()[0]['phase'],'notify_pending')
            self.assertIsNone(target.backend.load());self.assertEqual(tuple(probe.attempts.values()),(1,1,1,0))

    def test_delayed_shelf_keeps_acknowledged_identity_without_cleanup_or_replay(self):
        class InvisibleProbe(FakeProbe):
            def shelf(self,grant):
                value=super().shelf(grant)
                if self.attempts['notify']:value['books']=[row for row in value['books'] if row['bookId']!='CB_synthetic123']
                return value
        ext='mobi';journal=Journal(ext,Backend());target=TargetReceipt(ext,Backend());probe=InvisibleProbe()
        kwargs=dict(apply=True,sleep=lambda _:None,now=lambda:1000,fixture_builder=lambda:build(ext),
            prepare_plan=lambda grant,shelf,name:prepare(ext,grant,shelf,name),
            check_plan=lambda plan,grant,shelf,target=None,expected=False:check(ext,plan,grant,shelf,target,expected),
            fixture_extension=ext,readback_tries=9,notify_receipt=target.record)
        result=run(probe,journal,credentials(),lambda _:True,lambda _:True,**kwargs)
        self.assertEqual(result['reason'],'synthetic_epub/import_unconfirmed');self.assertEqual(journal.read()[0]['phase'],'notify_pending')
        self.assertEqual(json.loads(target.backend.load())['target'],'CB_synthetic123')
        self.assertEqual(tuple(probe.attempts.values()),(1,1,1,0))
        again=run(probe,journal,credentials(),lambda _:True,lambda _:True,**kwargs)
        self.assertEqual(again['reason'],'synthetic_epub/already_reserved');self.assertEqual(tuple(probe.attempts.values()),(1,1,1,0))


if __name__=='__main__':unittest.main()
