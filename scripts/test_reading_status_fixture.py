"""Synthetic tests; these never access the account, Keychain or network."""
from contextlib import redirect_stdout
from copy import deepcopy
import io
import json
import unittest
from unittest.mock import patch

from cloud_group_contract import project
from cloud_group_fixture import Journal, binding
from native_direct_time_trial_store import Intent
from personal_upload_trial import hash_value
from reading_status_fixture_trial import Trial, request
from synthetic_format_trial import TargetReceipt
from test_native_shelf_trial import source
from test_personal_upload_trial import FakeProbe, TARGET
from test_secure_native_session import Backend, credentials
from verify_reading_status_fixture import ScopedNative, main
from verify_synthetic_epub_upload import run as upload


def fixture():
    journal = Journal(Backend())
    receipt = TargetReceipt('epub', backend=Backend(), scope='group-fixture')
    upload(FakeProbe(), journal, credentials(), lambda _: True, lambda _: True, apply=True,
           sleep=lambda _: None, now=lambda: 1000, notify_receipt=receipt.record, cleanup_gate=lambda *_: False)
    return journal, receipt


class Service:
    def __init__(self, mode='ok'):
        self.mode = mode
        self.posts = []
        self.shelf = source()
        self.shelf['books'].append({'bookId': TARGET, 'title': 'Synthetic', 'finishReading': 0, 'secret': 0})
        self.flag = 0
        self.counter = 0

    def read(self, target):
        shelf = deepcopy(self.shelf)
        return {'native_shelf': shelf, 'web_shelf': deepcopy(shelf),
                'native_progress': {'book': {'bookId': target, 'isStartReading': self.flag,
                                             'chapterUid': 0, 'chapterOffset': 0, 'progress': 0},
                                    'readingTime': self.counter}}

    def send(self, kind, plan):
        self.posts.append(kind)
        self.assert_body = plan['body'] == request(TARGET, kind == 'restore')
        if self.mode == 'lost' and kind == 'mark':
            raise TimeoutError()
        if self.mode != 'no_effect':
            self.flag = int(kind == 'mark')
        if self.mode == 'counter' and kind == 'mark':
            self.counter = 1
        if self.mode == 'unrelated' and kind == 'mark':
            self.shelf['books'][0]['secret'] = 1
        if self.mode == 'target_changed' and kind == 'mark':
            self.shelf['books'][-1]['finishReading'] = 1
        return {} if self.mode == 'unknown_ack' else {'succ': 1}


class TrialTests(unittest.TestCase):
    def trial(self, service, current=lambda: True):
        journal, receipt = fixture()
        original = project(source())
        return Trial(journal, receipt, credentials(), current, lambda: True,
                     {'native': original, 'web': deepcopy(original)}, service.read, service.send)

    def test_roundtrip_requires_independent_observation_and_restoration(self):
        service = Service()
        result = self.trial(service).run(TARGET)
        self.assertEqual(result['result'], 'PASS')
        self.assertEqual(service.posts, ['mark', 'restore'])
        self.assertTrue(service.assert_body)
        self.assertEqual(result['changed_native_fields'], ['isStartReading'])
        self.assertNotIn(TARGET, json.dumps(result))

    def test_uncertain_or_unrelated_result_stops_without_restore(self):
        for mode in ('lost', 'unknown_ack', 'no_effect', 'counter', 'unrelated', 'target_changed'):
            with self.subTest(mode=mode):
                service = Service(mode)
                result = self.trial(service).run(TARGET)
                self.assertEqual(result['result'], 'UNVERIFIED')
                self.assertEqual(service.posts, ['mark'])

    def test_invalid_owner_and_nonzero_baseline_do_not_send(self):
        service = Service()
        self.assertEqual(self.trial(service, current=lambda: False).run(TARGET)['status_posts'], 0)
        service.flag = 1
        self.assertEqual(self.trial(service).run(TARGET)['status_posts'], 0)
        self.assertEqual(service.posts, [])

    def test_unstarted_coordinates_are_required_before_dispatch(self):
        for value in (1, True, None):
            with self.subTest(chapter=value):
                service = Service()
                original_read = service.read
                def read(target):
                    result = original_read(target)
                    result['native_progress']['book']['chapterUid'] = value
                    return result
                service.read = read
                self.assertEqual(self.trial(service).run(TARGET)['status_posts'], 0)
                self.assertEqual(service.posts, [])

    def test_transport_consumes_claim_before_sending_and_rejects_replay(self):
        journal, receipt = fixture()
        mark, restore = Intent(backend=Backend()), Intent(backend=Backend())
        grant = credentials()
        probe = ScopedNative(grant, lambda: True, lambda: True, journal, receipt,
                             {'mark': mark, 'restore': restore})
        state, _ = binding(journal, receipt.backend)
        plan = {'selection': {'owner': grant['vid'], 'target': TARGET, 'upload_attempt': state['attempt'],
                              'upload_plan_hash': hash_value(state['plan']), 'grant_hash': hash_value(grant)},
                'record': {'kind': 'mark'}, 'body': request(TARGET, False), 'baseline': {'snapshot_hash': 'a' * 64}}
        with patch('verify_eink_login.NativeProbe.request', side_effect=TimeoutError) as dispatch:
            with self.assertRaises(TimeoutError):
                probe.send('mark', plan)
            self.assertEqual(mark.read()[0]['phase'], 'claimed')
            with self.assertRaises(ValueError):
                probe.send('mark', plan)
            self.assertEqual(dispatch.call_count, 1)
        with self.assertRaises(ValueError):
            probe.request('other', 'https://example.com', body={})
        changed = deepcopy(plan)
        changed['body']['bookId'] = 'CB_other'
        fresh = ScopedNative(grant, lambda: True, lambda: True, journal, receipt,
                             {'mark': Intent(backend=Backend()), 'restore': restore})
        with self.assertRaises(ValueError):
            fresh.send('mark', changed)

    def test_default_does_not_access_keychain(self):
        with patch('verify_reading_status_fixture.SessionStore') as store, redirect_stdout(io.StringIO()) as out:
            self.assertEqual(main([]), 0)
        store.assert_not_called()
        self.assertEqual(json.loads(out.getvalue())['result'], 'OFFLINE_ONLY')


if __name__ == '__main__':
    unittest.main()
