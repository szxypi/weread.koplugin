import contextlib
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from run_my_mark_navigation_ui import COUNTS, FLAGS, FRAME, PERSONAL_FLAGS
from verify_cb_note_target import choose_chapter, main, native_ui


class CbNoteTargetTests(unittest.TestCase):
    def test_default_is_offline(self):
        with patch('verify_cb_note_target.SessionStore') as web, \
                patch('verify_cb_note_target.NativeSessionStore') as native, \
                patch('verify_cb_note_target.CbNotesProbe') as probe, \
                contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(main([]), 0)
        web.assert_not_called(); native.assert_not_called(); probe.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'], 'OFFLINE_ONLY')

    def test_target_chapter_must_be_unique(self):
        chapters = [{'chapterUid': 2}, {'chapterUid': 3}]
        self.assertEqual(choose_chapter(chapters, None, '2'), chapters[0])
        for rows, uid in ((chapters, '4'), (chapters + [{'chapterUid': 2}], '2')):
            with self.assertRaises(ValueError):
                choose_chapter(rows, None, uid)

    def test_native_result_requires_exact_target_and_temporary_cleanup(self):
        stages = []
        for mode in ('live', 'reopen'):
            row = dict.fromkeys(FLAGS, True)
            row.update(dict.fromkeys(COUNTS, 0))
            row.update(result='PASS', mode=mode, phase='complete', located=1, buttons=1, source_files=2)
            stages.append(row)
        result = dict(result='PASS', profile_removed=True, installed_bytes_match=True, stages=stages)
        child = SimpleNamespace(returncode=0, stdout=FRAME + json.dumps(result).encode())
        private = {'raw': 'private source sample'}
        with patch('verify_cb_note_target.subprocess.run', return_value=child) as run:
            summary = native_ui(['synthetic-runner'], private, 600, 800, 167)
        self.assertEqual(summary['located'], 1)
        self.assertNotIn('private source sample', json.dumps(summary))
        self.assertNotIn('private source sample', json.dumps(run.call_args.args[0]))
        result['profile_removed'] = False
        child.stdout = FRAME + json.dumps(result).encode()
        with patch('verify_cb_note_target.subprocess.run', return_value=child), self.assertRaises(ValueError):
            native_ui(['synthetic-runner'], private, 600, 800, 167)

    def test_personal_display_requires_both_complete_native_span_checks(self):
        stages=[]
        for mode in ('live','reopen'):
            row=dict.fromkeys(FLAGS|PERSONAL_FLAGS,True);row.update(dict.fromkeys(COUNTS,0))
            row.update(result='PASS',mode=mode,phase='complete',located=1,buttons=1,source_files=2,personal_spans=1)
            stages.append(row)
        result=dict(result='PASS',profile_removed=True,installed_bytes_match=True,stages=stages)
        child=SimpleNamespace(returncode=0,stdout=FRAME+json.dumps(result).encode())
        with patch('verify_cb_note_target.subprocess.run',return_value=child) as run:
            summary=native_ui(['synthetic-runner'],{},600,800,167,personal=True)
        self.assertTrue(summary['personal_display_verified'])
        self.assertIn('--personal-display',run.call_args.args[0])
        stages[1]['personal_native_text']=False
        child.stdout=FRAME+json.dumps(result).encode()
        with patch('verify_cb_note_target.subprocess.run',return_value=child),self.assertRaises(ValueError):
            native_ui(['synthetic-runner'],{},600,800,167,personal=True)


if __name__ == '__main__':
    unittest.main()
