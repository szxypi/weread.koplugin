"""Offline tests for native imported-style step ownership and no replay."""
import contextlib
from copy import deepcopy
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from cb_fixture_style_trial import Intent, prepare
from verify_cb_fixture_color_native import prepare as prepare_color
from test_cb_fixture_highlight_trial import fixture
from test_secure_native_session import Backend
from verify_cb_fixture_style_native import main, run_ui


class Frames:
    def __init__(self, body, state, armed, fault=None, palette=False):
        self.body = body; self.state = state; self.armed = armed; self.fault = fault; self.step = 0; self.palette=palette
    def next(self):
        self.step += 1; seq = self.step
        if not self.armed:
            return ('STEP', {'seq': 0, 'preview': self.body}) if seq == 1 else ('RESULT', self.result(False))
        marks = self.state['marks']['updated']
        if seq == 1: marks['synthetic-new'] = dict(self.body, bookmarkId='synthetic-new')
        elif seq in (2, 3):
            if self.palette: marks['synthetic-new']['colorStyle'] = {2: 0, 3: 3}[seq]
            else: marks['synthetic-new']['style'] = {2: 0, 3: 2}[seq]
            if self.fault == 'changed-field' and seq == 2: marks['synthetic-new']['markText'] = 'changed'
        elif seq == 4: marks.clear()
        else: return 'RESULT', self.result(True)
        return 'STEP', {'seq': seq, 'created_id': 'wrong' if self.fault == 'wrong-id' and seq == 2 else 'synthetic-new'}
    @staticmethod
    def result(armed):
        return dict(result='PASS' if armed else 'DRY_RUN', profile_removed=True, installed_bytes_match=True, stage=None,
                    native_controls=True, writes=4 if armed else 0, fresh_offline=armed, credentials_not_persisted=True)


class Tests(unittest.TestCase):
    def test_offline_does_not_load_credentials(self):
        with patch('verify_cb_fixture_style_native.SessionStore') as store, contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(main([]), 0)
        store.assert_not_called(); self.assertEqual(json.loads(output.getvalue())['result'], 'OFFLINE_ONLY')

    def run_case(self, armed, fault=None, palette=False):
        sample, baseline, _, _ = fixture(); plan, body = (prepare_color if palette else prepare)('900000', sample['book_id'], 'a'*32, sample, 1, baseline)
        state = deepcopy(baseline); intent = Intent(Backend())
        process = SimpleNamespace(stdin=io.BytesIO(), stdout=io.BytesIO(), wait=lambda **_kwargs: 0)
        frames = Frames(body, state, armed, fault, palette)
        with patch('verify_cb_fixture_style_native.subprocess.Popen', return_value=process), \
             patch('verify_cb_fixture_style_native.Frames', return_value=frames), \
             patch('verify_cb_fixture_style_native.stop'):
            def execute(): return run_ui(['synthetic'], {}, plan, body, baseline, intent, lambda: True, lambda: deepcopy(state), armed=armed, palette=palette)
            if fault:
                with self.assertRaises(ValueError): execute()
                self.assertEqual(intent.read()[0]['phase'], 'straight_pending')
                with self.assertRaises(ValueError): execute()
                return
            result = execute()
        self.assertEqual(result['writes'], 4 if armed else 0); self.assertEqual(intent.read(), (None, None))
        self.assertEqual(state, baseline)

    def test_blocked_preview_and_four_independent_steps(self):
        self.run_case(False); self.run_case(True)

    def test_wrong_target_and_unrelated_change_stop_without_retry(self):
        self.run_case(True, 'wrong-id'); self.run_case(True, 'changed-field')

    def test_native_color_scope_and_no_replay(self):
        self.run_case(False, palette=True); self.run_case(True, palette=True)
        self.run_case(True, 'wrong-id', palette=True); self.run_case(True, 'changed-field', palette=True)

    def test_unowned_fixture_never_starts_child(self):
        sample, baseline, _, _ = fixture(); plan, body = prepare('900000', sample['book_id'], 'a'*32, sample, 1, baseline)
        intent = Intent(Backend())
        with patch('verify_cb_fixture_style_native.subprocess.Popen') as child:
            with self.assertRaises(ValueError): run_ui(['synthetic'], {}, plan, body, baseline, intent, lambda: False, lambda: baseline, armed=True)
        child.assert_not_called(); self.assertEqual(intent.read(), (None, None))


if __name__ == '__main__': unittest.main()
