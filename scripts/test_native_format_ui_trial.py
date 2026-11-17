"""Native format upload scopes require fixed bytes and exact owned cleanup."""
import unittest
from native_epub_ui_trial import run
from native_format_ui_trial import Journal,check,prepare
from synthetic_format_trial import TargetReceipt
from test_native_personal_upload_trial import FakeProbe
from test_secure_native_session import Backend,credentials


class NativeFormatUITest(unittest.TestCase):
    def test_each_format_is_scoped_and_cannot_replay(self):
        for ext in ('pdf','mobi','azw3'):
            with self.subTest(ext=ext):
                journal=Journal(ext,Backend());target=TargetReceipt(ext,Backend(),scope='native-ui');probe=FakeProbe()
                options=dict(apply=True,sleep=lambda _:None,prepare_plan=lambda grant,shelf,name:prepare(ext,grant,shelf,name),
                    check_plan=lambda plan,grant,shelf,target=None,expected=False:check(ext,plan,grant,shelf,target,expected),
                    fixture_extension=ext,readback_tries=9,notify_receipt=target.record)
                report=run(probe,journal,credentials(),lambda _:True,lambda _:True,probe.spawn,**options)
                self.assertEqual(report['result'],'NATIVE_'+ext.upper()+'_UI_AND_SOURCE_VERIFIED')
                self.assertEqual(journal.read()[0]['phase'],'restored');self.assertIsNotNone(target.backend.load())
                self.assertEqual((probe.spawns,probe.cleanups),(1,1))
                again=run(probe,journal,credentials(),lambda _:True,lambda _:True,probe.spawn,**options)
                self.assertEqual(again['reason'],'epub_ui/already_reserved');self.assertEqual((probe.spawns,probe.cleanups),(1,1))

    def test_unknown_child_result_never_cleans_or_persists_target(self):
        for ext in ('pdf','mobi','azw3'):
            probe=FakeProbe('child_lost');journal=Journal(ext,Backend());target=TargetReceipt(ext,Backend(),scope='native-ui')
            result=run(probe,journal,credentials(),lambda _:True,lambda _:True,probe.spawn,apply=True,sleep=lambda _:None,
                prepare_plan=lambda grant,shelf,name:prepare(ext,grant,shelf,name),
                check_plan=lambda plan,grant,shelf,target=None,expected=False:check(ext,plan,grant,shelf,target,expected),
                fixture_extension=ext,notify_receipt=target.record)
            self.assertEqual(result['result'],'UNVERIFIED');self.assertEqual((probe.spawns,probe.cleanups),(1,0))
            self.assertIsNone(target.backend.load());self.assertEqual(journal.read()[0]['phase'],'launched')


if __name__=='__main__':unittest.main()
