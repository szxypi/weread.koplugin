"""Offline account-state roundtrip and one-shot proof gates for native UI trials."""
from copy import deepcopy
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from native_direct_time_trial_store import Intent
from ordinary_reading_status_trial import STAGES
from run_owner_reading_state_change_ui import FRAME
from test_native_shelf_trial import source
from test_owner_reading_state_change_ui import envelope
from test_secure_native_session import Backend, credentials
import verify_ordinary_started_native_ui as task


class Tests(unittest.TestCase):
    def test_complete_orchestrator_claims_before_native_and_requires_ui_proofs(self):
        self.roundtrip()

    def test_lost_native_result_never_authorizes_restore_or_replay(self):
        self.roundtrip(lost=True)

    def roundtrip(self, lost=False):
        grant = credentials();saved = {'vid': grant['vid'], 'cookies': {'synthetic': 'cookie'}}
        plan_store = Intent(backend=Backend())
        actions = {stage: Intent(backend=Backend()) for stage in STAGES}
        proofs = {stage: Intent(backend=Backend()) for stage in STAGES}
        ui_proofs = {stage: Intent(backend=Backend()) for stage in ('mark', 'restore')}
        state = {'shelf': source(), 'book': {'bookId': '99', 'isStartReading': 0, 'startReadingTime': 0,
                 'chapterUid': 0, 'chapterOffset': 0, 'progress': 0, 'readingTime': 0, 'recordReadingTime': 0,
                 'ttsTime': 0}, 'posts': []}
        class Web:
            def verify_account(self): pass
            def request(self, *_): return deepcopy(state['shelf'])
        class Store:
            def load(self, *_): return deepcopy(saved)
        class NativeStore:
            def load(self, *_): return deepcopy(grant)
        def wire(_self, stage, url, body=None, credentials=None, timeout=15):
            assert credentials == grant and timeout == 15
            if stage == 'shelf': return deepcopy(state['shelf'])
            if stage == 'progress': return {'book': deepcopy(state['book'])}
            if stage == 'marks': return {'updated': [], 'chapters': []}
            if stage == 'thoughts': return {'reviews': [], 'totalCount': 0, 'hasMore': 0}
            assert stage == 'write' and body is not None
            if url.endswith('/shelf/add'):
                state['shelf']['books'].append({'bookId': '99', 'title': 'Synthetic target', 'finishReading': 0})
                kind = 'add'
            elif url.endswith('/shelf/delete'):
                state['shelf']['books'] = [row for row in state['shelf']['books'] if row['bookId'] != '99']
                kind = 'remove'
            else: raise AssertionError('status writes must use native UI')
            state['posts'].append(kind);return {'succ': 1}
        def native(_command, input, capture_output, timeout):
            value = json.loads(input);kind = 'mark' if value['desired'] else 'restore'
            assert value['armed'] is True and value['book_id'] == '99' and capture_output and timeout == 180
            assert actions[kind].read()[0]['phase'] == 'claimed'
            assert proofs[kind].read()[0] is None and ui_proofs[kind].read()[0] is None
            state['book'].update(isStartReading=int(kind == 'mark'), startReadingTime=123 if kind == 'mark' else 0)
            state['posts'].append(kind)
            return SimpleNamespace(returncode=1 if lost and kind == 'mark' else 0,
                                   stdout=FRAME+json.dumps(envelope(True)).encode())
        with patch('verify_ordinary_reading_status.SessionStore', return_value=Store()), \
             patch('verify_ordinary_reading_status.NativeSessionStore', return_value=NativeStore()), \
             patch('verify_ordinary_reading_status.no_other_pending', return_value=True), \
             patch('verify_ordinary_reading_status.select_book', return_value=({'book_id': '99'}, {})), \
             patch.object(task, 'SessionStore', return_value=Store()), \
             patch.object(task, 'NativeSessionStore', return_value=NativeStore()), \
             patch.object(task, 'no_other_pending', return_value=True), \
             patch('verify_eink_login.NativeProbe.request', new=wire), \
             patch.object(task.subprocess, 'run', side_effect=native) as child:
            def run(stage, command=None):
                return task.execute(saved, grant, Web(), plan_store, actions, proofs, ui_proofs, stage, command)
            self.assertEqual(run('preview')['result'], 'READ_ONLY_PREVIEW')
            self.assertEqual(run('prepare')['result'], 'PREPARED')
            self.assertEqual(run('add')['result'], 'OBSERVED')
            with self.assertRaises(ValueError): run('restore', ['native-armed'])
            result = run('mark', ['native-armed'])
            if lost:
                self.assertEqual(result['result'], 'UNVERIFIED')
                self.assertEqual(proofs['mark'].read()[0]['phase'], 'claimed')
                self.assertIsNone(ui_proofs['mark'].read()[0])
                with self.assertRaises(ValueError): run('restore', ['native-armed'])
                result = run('mark', ['native-armed'])
                self.assertEqual(result['result'], 'UNVERIFIED')
                self.assertEqual(child.call_count, 1)
                self.assertEqual(state['posts'], ['add', 'mark'])
                return
            self.assertEqual(result['result'], 'OBSERVED');self.assertTrue(result['native_ui_verified'])
            self.assertEqual(run('restore', ['native-armed'])['result'], 'OBSERVED')
            self.assertEqual(run('remove')['result'], 'OBSERVED')
            self.assertEqual(run('audit')['result'], 'RESTORED_READ_ONLY')
            self.assertEqual(child.call_count, 2)
        self.assertEqual(state['posts'], list(STAGES));self.assertEqual(state['shelf'], source())
        self.assertEqual(state['book']['isStartReading'], 0);self.assertEqual(state['book']['startReadingTime'], 0)

    def test_future_or_unbound_proof_never_authorizes_a_stage(self):
        proofs = {name: Intent(backend=Backend()) for name in STAGES}
        ui = {name: Intent(backend=Backend()) for name in ('mark', 'restore')}
        selection = {'owner': '900000', 'book_id': '99'}
        ui['mark'].claim(dict(selection=selection, record={'kind': 'mark_native_ui_verified'}, body={}, baseline={}))
        for stage in ('add', 'mark', 'restore', 'remove'):
            with self.subTest(stage=stage), self.assertRaises(ValueError):
                task.check_ui_proofs(stage, selection, proofs, ui)


if __name__ == '__main__':
    unittest.main()
