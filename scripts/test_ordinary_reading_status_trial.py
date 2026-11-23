"""Synthetic staged trial tests; no account or network access."""
from copy import deepcopy
import unittest
from unittest.mock import patch

from native_direct_time_trial_store import Intent
from ordinary_reading_status_trial import STAGES, progress, request, run
from test_secure_native_session import Backend, credentials
from verify_ordinary_reading_status import ScopedNative, execute
from personal_upload_trial import hash_value
from test_native_shelf_trial import source


def snapshot():
    return {'native_shelf': 'native-baseline', 'web_shelf': 'web-baseline', 'marks': 'empty-marks',
            'thoughts': 'empty-thoughts', 'present': False, 'target_flags': None,
            'progress': {'flag': 0, 'start_time': 0, 'position': {'chapterUid': 0, 'readingTime': 0,
                       'recordReadingTime': 0, 'ttsTime': 0}}}


class Service:
    def __init__(self, mode='normal'):
        self.value = snapshot()
        self.actions = {stage: Intent(backend=Backend()) for stage in STAGES}
        self.proofs = {stage: Intent(backend=Backend()) for stage in STAGES}
        self.plan = {'selection': {'owner': '900000', 'book_id': '42'}, 'baseline': snapshot()}
        self.sent, self.mode = [], mode
    def observe(self):
        return deepcopy(self.value)
    def send(self, stage, path, plan):
        assert (path, plan['body']) == request(stage, '42')
        self.actions[stage].claim(plan)
        self.sent.append(stage)
        if stage == 'add':
            self.value.update(present=True, target_flags={'finished': 0})
        elif stage == 'mark':
            self.value['progress'].update(flag=1, start_time=123)
        elif stage == 'restore':
            self.value['progress'].update(flag=0, start_time=0)
        else:
            self.value.update(present=False, target_flags=None)
        if self.mode == 'foreign' and stage == 'mark':
            self.value['native_shelf'] = 'changed'
        if self.mode == 'lost' and stage == 'mark':
            raise TimeoutError()
        return {'succ': 1} if stage in ('add', 'remove') and self.mode != 'unknown_add' else {}
    def step(self, stage):
        return run(stage, self.plan, self.actions, self.proofs, lambda: True, self.observe, self.send,
                   sleep=lambda _: None)


class TrialTests(unittest.TestCase):
    def test_four_stages_are_observed_and_never_replayed(self):
        service = Service()
        for stage in STAGES:
            result = service.step(stage)
            self.assertEqual(result['result'], 'OBSERVED')
            self.assertTrue(result['independent_readback'])
        self.assertEqual(service.value, snapshot())
        self.assertEqual(service.sent, list(STAGES))
        self.assertFalse(service.proofs['mark'].read()[0]['plan']['record']['acknowledged'])
        self.assertEqual(service.step('mark')['data_posts'], 0)
        self.assertEqual(service.sent, list(STAGES))

    def test_unknown_add_or_foreign_change_blocks_later_stages(self):
        service = Service('unknown_add')
        self.assertEqual(service.step('add')['phase'], 'add_ack_unverified')
        self.assertEqual(service.step('mark')['data_posts'], 0)
        self.assertEqual(service.sent, ['add'])
        service = Service('foreign')
        self.assertEqual(service.step('add')['result'], 'OBSERVED')
        self.assertEqual(service.step('mark')['result'], 'UNVERIFIED')
        self.assertEqual(service.step('restore')['data_posts'], 0)
        self.assertEqual(service.sent, ['add', 'mark'])

    def test_lost_mark_receipt_records_only_observation_then_rechecks(self):
        service = Service('lost')
        self.assertEqual(service.step('add')['result'], 'OBSERVED')
        mark = service.step('mark')
        self.assertEqual(mark['result'], 'OBSERVED')
        self.assertFalse(mark['acknowledged'])
        service.value['progress']['position']['readingTime'] = 1
        self.assertEqual(service.step('restore')['data_posts'], 0)
        self.assertEqual(service.sent, ['add', 'mark'])

    def test_rejects_unknown_counter_and_invalid_targets(self):
        with self.assertRaises(ValueError):
            progress({'book': {'bookId': '42', 'isStartReading': 0, 'startReadingTime': 0}}, '42')
        for bad in ('CB_foo', '0', '4/2', '0001'):
            with self.assertRaises(ValueError):
                request('mark', bad)

    def test_transport_claims_before_dispatch_and_blocks_unproven_phases(self):
        grant = credentials()
        selection = {'owner': grant['vid'], 'book_id': '42', 'grant_hash': hash_value(grant)}
        actions = {stage: Intent(backend=Backend()) for stage in STAGES}
        proofs = {stage: Intent(backend=Backend()) for stage in STAGES}
        native = ScopedNative(grant, selection, actions, proofs, lambda: True)
        def plan(stage):
            return {'selection': selection, 'record': {'kind': stage}, 'body': request(stage, '42')[1],
                    'baseline': {'snapshot_hash': 'a' * 64}}
        with patch('verify_eink_login.NativeProbe.request', side_effect=TimeoutError) as dispatch:
            with self.assertRaises(ValueError):
                native.send('mark', request('mark', '42')[0], plan('mark'))
            with self.assertRaises(TimeoutError):
                native.send('add', request('add', '42')[0], plan('add'))
            self.assertEqual(actions['add'].read()[0]['phase'], 'claimed')
            with self.assertRaises(ValueError):
                native.send('add', request('add', '42')[0], plan('add'))
            self.assertEqual(dispatch.call_count, 1)
        with self.assertRaises(ValueError):
            native.request('escape', 'https://example.com', body={})

    def test_actual_orchestrator_runs_full_synthetic_roundtrip(self):
        grant = credentials()
        saved = {'vid': grant['vid'], 'cookies': {'synthetic': 'cookie'}}
        plan_store = Intent(backend=Backend())
        actions = {stage: Intent(backend=Backend()) for stage in STAGES}
        proofs = {stage: Intent(backend=Backend()) for stage in STAGES}
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
            else:
                kind = 'restore' if body['isCancel'] else 'mark'
                state['book'].update(isStartReading=int(kind == 'mark'), startReadingTime=123 if kind == 'mark' else 0)
            state['posts'].append(kind)
            return {'succ': 1} if kind in ('add', 'remove') else {'status': 1}
        with patch('verify_ordinary_reading_status.SessionStore', return_value=Store()), \
             patch('verify_ordinary_reading_status.NativeSessionStore', return_value=NativeStore()), \
             patch('verify_ordinary_reading_status.no_other_pending', return_value=True), \
             patch('verify_ordinary_reading_status.select_book', return_value=({'book_id': '99'}, {})), \
             patch('verify_eink_login.NativeProbe.request', new=wire):
            self.assertEqual(execute(saved, grant, Web(), plan_store, actions, proofs, 'preview')['result'], 'READ_ONLY_PREVIEW')
            self.assertEqual(execute(saved, grant, Web(), plan_store, actions, proofs, 'prepare')['result'], 'PREPARED')
            for stage in STAGES:
                self.assertEqual(execute(saved, grant, Web(), plan_store, actions, proofs, stage)['result'], 'OBSERVED')
        self.assertEqual(state['posts'], list(STAGES))
        self.assertEqual(state['shelf'], source())
        self.assertEqual(state['book']['isStartReading'], 0)
        self.assertEqual(state['book']['startReadingTime'], 0)


if __name__ == '__main__':
    unittest.main()
