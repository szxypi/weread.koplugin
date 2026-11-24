"""Offline checks of the imported fixture's isolated native UI transport."""
from copy import deepcopy
from contextlib import redirect_stdout
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from cloud_group_fixture import binding
from cloud_group_fixture import Journal
from imported_started_ui_trial import plan, run
from native_direct_time_trial_store import Intent
from run_owner_reading_state_change_ui import FRAME
from synthetic_format_trial import TargetReceipt
from test_imported_started_ui_trial import snapshot
from test_owner_reading_state_change_ui import envelope
from test_personal_upload_trial import TARGET, FakeProbe
from test_reading_status_fixture import fixture
from test_secure_native_session import Backend, credentials
from verify_synthetic_epub_upload import run as real_upload
import verify_imported_started_native_ui as task


def setup(mode='normal'):
    journal, receipt = fixture();grant = credentials()
    intents = {name: Intent(backend=Backend()) for name in ('baseline', 'mark', 'mark-proof', 'restore', 'restore-proof')}
    native = task.ScopedUI(grant, lambda: True, lambda: True, journal, receipt, intents, ['synthetic-native'])
    state, _ = binding(journal, receipt.backend);identity = task.selection(state, grant);value = snapshot();sent = []
    native.observer = lambda: deepcopy(value)
    native.shelf = lambda: {'books': [], 'archive': []}
    native.progress = lambda _id: {'book': {}}
    def child(command, input, capture_output, timeout):
        payload = json.loads(input);kind = 'mark' if payload['desired'] else 'restore'
        assert payload['book_id'] == TARGET and payload['armed'] is True and capture_output and timeout == 180
        assert command[-1] == '--armed' and intents[kind].read()[0]['phase'] == 'claimed'
        assert intents[kind+'-proof'].read()[0] is None
        sent.append(kind)
        if mode != 'no_effect':
            value['progress'].update(flag=int(kind == 'mark'), start_time=123 if kind == 'mark' else 0)
            value['observed'].update(isStartReading=int(kind == 'mark'), startReadingTime=123 if kind == 'mark' else 0)
        return SimpleNamespace(returncode=1 if mode == 'lost' else 0, stdout=FRAME+json.dumps(envelope(True)).encode())
    return native, identity, value, sent, intents, child


class Tests(unittest.TestCase):
    def test_entire_upload_native_roundtrip_cleanup_and_new_process_audit(self):
        self.orchestrate()

    def test_uncertain_native_result_keeps_fixture_and_refuses_replay(self):
        self.orchestrate(lost=True)

    def orchestrate(self, lost=False):
        grant = credentials();saved = {'vid': grant['vid'], 'cookies': {'synthetic': 'cookie'}}
        journal = Journal(Backend());receipt = TargetReceipt('epub', backend=Backend(), scope='group-fixture')
        intents = {name: Intent(backend=Backend()) for name in ('baseline', 'mark', 'mark-proof', 'restore', 'restore-proof')}
        fake = FakeProbe();flag = {'value': 0};sent = [];web_override = {'value': None}
        class Store:
            def load(self, *_): return deepcopy(saved)
        class NativeStore:
            def load(self, *_): return deepcopy(grant)
        class Web:
            def verify_account(self): pass
            def request(self, *_): return deepcopy(web_override['value'] if web_override['value'] is not None else fake.state)
        def point(_self, target):
            return {'book': {'bookId': target, 'isStartReading': flag['value'],
                'startReadingTime': 123 if flag['value'] else 0, 'chapterUid': 0, 'chapterIdx': 0,
                'chapterOffset': 0, 'progress': 0, 'summary': '', 'readingTime': 0, 'recordReadingTime': 0, 'ttsTime': 0}}
        def personal(_self, target):
            assert target == TARGET
            return {'updated': {}, 'chapters': {}}, {}
        def child(_command, input, capture_output, timeout):
            value = json.loads(input);kind = 'mark' if value['desired'] else 'restore'
            assert value['book_id'] == TARGET and value['armed'] and capture_output and timeout == 180
            assert intents[kind].read()[0]['phase'] == 'claimed'
            flag['value'] = int(kind == 'mark');sent.append(kind)
            return SimpleNamespace(returncode=1 if lost else 0, stdout=FRAME+json.dumps(envelope(True)).encode())
        def upload(*args, **kwargs): return real_upload(*args, **kwargs, sleep=lambda _: None, now=lambda: 1000)
        def native_shelf(_self): return deepcopy(fake.state)
        def read_shelf(_self, _stage, _url, body=None, credentials=None, timeout=15):
            assert body is None and credentials == grant and timeout == 15
            return deepcopy(fake.state)
        with patch.object(task, 'SessionStore', return_value=Store()), \
             patch.object(task, 'no_other_pending', return_value=True), \
             patch.object(task, 'UploadProbe', return_value=fake), \
             patch.object(task, 'read_source', return_value=True), \
             patch.object(task, 'upload', side_effect=upload), \
             patch.object(task.FixtureProbe, 'shelf', native_shelf), \
             patch.object(task.FixtureProbe, 'progress', point), \
             patch.object(task.ScopedUI, 'personal', personal), \
             patch.object(task.NativeProbe, 'request', read_shelf), \
             patch.object(task.subprocess, 'run', side_effect=child) as runner:
            result = task.execute(saved, NativeStore(), Web(), journal, receipt, intents, apply=True, command=['synthetic-native'])
            if lost:
                self.assertEqual(result['result'], 'UNVERIFIED');self.assertEqual(result['status_posts'], 1)
                self.assertEqual(journal.read()[0]['phase'], 'imported');self.assertEqual(fake.attempts['cleanup'], 0)
                self.assertEqual(sent, ['mark']);self.assertIsNone(intents['mark-proof'].read()[0])
                again = task.execute(saved, NativeStore(), Web(), journal, receipt, intents, apply=True, command=['synthetic-native'])
                self.assertEqual(again['result'], 'UNVERIFIED');self.assertEqual(runner.call_count, 1)
                return
            self.assertEqual(result['result'], 'PASS');self.assertEqual(result['status_posts'], 2)
            self.assertTrue(result['full_shelf_restored']);self.assertEqual(fake.attempts['cleanup'], 1)
            self.assertEqual(journal.read()[0]['phase'], 'restored');self.assertEqual(sent, ['mark','restore'])
            result = task.audit(saved, NativeStore(), Web(), journal, receipt, intents)
            self.assertEqual(result['result'], 'RESTORED_READ_ONLY');self.assertEqual(result['account_data_writes'], 0)
            self.assertTrue(result['native_full_snapshot_matches_initial'])
            web_override['value'] = deepcopy(fake.state);fake.state['archive'][0]['syntheticMetadata'] = 1
            result = task.audit(saved, NativeStore(), Web(), journal, receipt, intents)
            self.assertEqual(result['result'], 'CORE_RESTORED_NATIVE_SNAPSHOT_CHANGED')
            self.assertFalse(result['native_full_snapshot_matches_initial']);self.assertTrue(result['web_full_snapshot_matches_initial'])
            fake.state['archive'][0]['name'] = 'changed core group'
            with self.assertRaises(ValueError): task.audit(saved, NativeStore(), Web(), journal, receipt, intents)

    def test_full_roundtrip_claims_each_write_then_saves_readback_proof(self):
        native, identity, value, sent, intents, child = setup()
        with patch.object(task.subprocess, 'run', side_effect=child):
            result = run(identity, lambda: deepcopy(value), native.send, native.proof, lambda: True)
        self.assertEqual(result['result'], 'PASS');self.assertEqual(sent, ['mark', 'restore'])
        self.assertEqual(value, snapshot())
        for kind in ('mark', 'restore'):
            self.assertTrue(task.proof_matches(intents[kind+'-proof'].read()[0], intents[kind].read()[0], identity, kind))
        self.assertEqual(intents['restore'].read()[0]['plan']['baseline'], intents['mark-proof'].read()[0]['plan']['baseline'])
        self.assertEqual(intents['restore-proof'].read()[0]['plan']['baseline'], intents['mark'].read()[0]['plan']['baseline'])

    def test_lost_ui_result_blocks_restore_and_durable_mark_prevents_replay(self):
        native, identity, value, sent, intents, child = setup('lost')
        with patch.object(task.subprocess, 'run', side_effect=child):
            result = run(identity, lambda: deepcopy(value), native.send, native.proof, lambda: True)
            self.assertEqual(result['result'], 'UNVERIFIED');self.assertEqual(sent, ['mark'])
            self.assertIsNone(intents['mark-proof'].read()[0])
            with self.assertRaises(ValueError): native.send('restore', plan(identity, 'restore', value))
            with self.assertRaises(ValueError): native.send('mark', plan(identity, 'mark', snapshot()))
        self.assertEqual(sent, ['mark'])

    def test_mismatched_target_scope_or_unverified_mark_cannot_dispatch(self):
        native, identity, value, sent, _intents, child = setup()
        with patch.object(task.subprocess, 'run', side_effect=child):
            for kind, action in (('restore', plan(identity, 'restore', value)),
                                 ('mark', plan(dict(identity, target='CB_other'), 'mark', value))):
                with self.assertRaises(ValueError): native.send(kind, action)
        self.assertEqual(sent, [])

    def test_changed_preflight_blocks_dispatch_before_claim(self):
        native, identity, value, sent, intents, child = setup();action = plan(identity, 'mark', value)
        value['progress']['position']['readingTime'] = 1
        with patch.object(task.subprocess, 'run', side_effect=child):
            with self.assertRaises(ValueError): native.send('mark', action)
        self.assertIsNone(intents['mark'].read()[0]);self.assertEqual(sent, [])

    def test_missing_or_malformed_proofs_cannot_pass_audit_gate(self):
        native, identity, value, _sent, intents, child = setup()
        with patch.object(task.subprocess, 'run', side_effect=child):
            self.assertTrue(native.send('mark', plan(identity, 'mark', value)))
        action = intents['mark'].read()[0]
        self.assertFalse(task.proof_matches(None, action, identity, 'mark'))
        bad = {'phase': 'claimed', 'plan': {'selection': identity, 'record': {'kind': 'mark_ui_observed'},
                'body': {}, 'baseline': {'snapshot_hash': 'not-a-hash'}}}
        self.assertFalse(task.proof_matches(bad, action, identity, 'mark'))

    def test_offline_default_does_not_access_session(self):
        with patch.object(task, 'SessionStore') as store, redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]), 0)
        store.assert_not_called();self.assertEqual(json.loads(out.getvalue())['result'], 'OFFLINE_ONLY')


if __name__ == '__main__': unittest.main()
