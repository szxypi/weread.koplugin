import contextlib
import io
import json
import unittest
from unittest.mock import patch

import verify_ordinary_partial_recovery as task
from test_secure_ordinary_reconnect_trial import plan


class RecoveryCliTests(unittest.TestCase):
    def test_default_is_offline_without_keychain(self):
        with patch.object(task,'SessionStore') as session,patch.object(task,'OrdinaryReconnectStore') as original, \
             contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]),0)
        session.assert_not_called();original.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'],'OFFLINE_ONLY')
    def test_modes_require_explicit_session(self):
        for args in (['--prepare'],['--apply'],['--retry'],['--retry','--prepare'],['--saved-session'],['--saved-session','--apply','--prepare']):
            with self.subTest(args=args),contextlib.redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):task.main(args)
    def test_wrong_original_intent_stops_before_credentials(self):
        for state in (None,{'phase':'prepared','posts':0},{'phase':'retired','posts':3}):
            with self.subTest(state=state),patch.object(task,'OrdinaryReconnectStore') as original, \
                 patch.object(task,'PartialRecoveryStore') as recovery,patch.object(task,'SessionStore') as session, \
                 contextlib.redirect_stdout(io.StringIO()) as out:
                original.return_value.read.return_value=(state,None)
                recovery.return_value.read.return_value=(None,None)
                self.assertEqual(task.main(['--saved-session','--prepare']),1)
            session.assert_not_called();self.assertEqual(json.loads(out.getvalue())['reason'],'ordinary_recovery/intent')

    def test_retry_only_selects_a_known_observed_position(self):
        selected=plan();entered=task.observed_point(selected)
        def raw(point):return {'book':dict(bookId=point['book_id'],chapterUid=point['chapter_uid'],chapterIdx=point['chapter_idx'],
                                           chapterOffset=point['chapter_offset'],progress=point['raw_percent'],summary=point['summary'])}
        self.assertEqual(task.choose_retry_state(selected,'enter_pending',raw(entered))[0],'entered')
        self.assertEqual(task.choose_retry_state(selected,'position_pending',raw(selected['target']))[0],'target')
        with self.assertRaises(ValueError):task.choose_retry_state(selected,'enter_pending',raw(selected['target']))
        with self.assertRaises(ValueError):task.choose_retry_state(selected,'restore_pending',raw(entered))
        wrong=raw(entered);wrong['book']['summary']='other'
        with self.assertRaises(ValueError):task.choose_retry_state(selected,'position_pending',wrong)


if __name__=='__main__':unittest.main()
