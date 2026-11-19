import contextlib
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from run_my_cloud_marks_ui import FLAGS, FRAME
from verify_cb_personal_notes import CbNotesProbe, main, native_ui
from verify_eink_login import NativeProbe


class CbNotesTests(unittest.TestCase):
    def test_default_is_offline_and_does_not_load_sessions(self):
        with patch('verify_cb_personal_notes.SessionStore') as web, \
                patch('verify_cb_personal_notes.NativeSessionStore') as native, \
                patch('verify_cb_personal_notes.CbNotesProbe') as probe, \
                contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(main([]), 0)
        web.assert_not_called(); native.assert_not_called(); probe.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'], 'OFFLINE_ONLY')

    def test_read_guard_rejects_unselected_books_writes_and_repeats(self):
        probe = CbNotesProbe(); probe.ids = {'CB_Synthetic'}
        with patch.object(NativeProbe, 'request', return_value={}) as request:
            for kind, identity in [('marks', 'CB_Other'), ('marks', 'CB_Synthetic&x=1'),
                                   ('delete', 'CB_Synthetic'), ('thoughts', '900001')]:
                with self.assertRaises(ValueError):
                    probe.read(kind, identity, {})
            with self.assertRaises(ValueError):
                probe.request('delete', 'https://i.weread.qq.com/book/removeBookmark', {})
            request.assert_not_called()
            probe.read('marks', 'CB_Synthetic', {})
            probe.read('thoughts', 'CB_Synthetic', {})
            for kind in ('marks', 'thoughts'):
                with self.assertRaises(ValueError):
                    probe.read(kind, 'CB_Synthetic', {})
            probe.shelf({}); probe.shelf({})
            with self.assertRaises(ValueError):
                probe.shelf({})
            self.assertEqual(request.call_count, 4)
            self.assertTrue(all(call.kwargs.get('body') is None for call in request.call_args_list))

    def test_native_ui_requires_matching_snapshot_and_temporary_profile_cleanup(self):
        snapshot = {'book_id': 'CB_Synthetic', 'updated': [{'markText': 'private fixture'}]}
        stages = []
        for mode in ('live', 'reopen'):
            row = dict.fromkeys(FLAGS, True)
            row.update(result='PASS', mode=mode, phase='complete', screenshots=0, pages=1,
                       quotes=1, requests=int(mode == 'live'), forbidden=0, failed_line=0, fault_cases=0)
            stages.append(row)
        ui = dict(result='PASS', profile_removed=True, installed_bytes_match=True, stages=stages)
        payload = {'model': snapshot, 'native': snapshot, 'ui': ui}
        credentials = {'vid': '900000', 'accessToken': 'private-fixture-token'}
        child = SimpleNamespace(returncode=0, stdout=FRAME + json.dumps(payload).encode())
        with patch('verify_cb_personal_notes.subprocess.run', return_value=child) as run:
            result = native_ui(['synthetic-runner'], {}, 'CB_Synthetic', '900000', credentials,
                               1000, None, snapshot, 600, 800, 167)
        self.assertEqual(result['rows'], 1)
        self.assertNotIn(credentials['accessToken'], json.dumps(run.call_args.args[0]))
        self.assertNotIn('private fixture', json.dumps(result))
        ui['profile_removed'] = False
        child.stdout = FRAME + json.dumps(payload).encode()
        with patch('verify_cb_personal_notes.subprocess.run', return_value=child), self.assertRaises(ValueError):
            native_ui(['synthetic-runner'], {}, 'CB_Synthetic', '900000', credentials,
                      1000, None, snapshot, 600, 800, 167)


if __name__ == '__main__':
    unittest.main()
