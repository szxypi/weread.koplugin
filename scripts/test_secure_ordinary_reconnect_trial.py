"""No network, real credentials, or real Keychain are used in these tests."""
import copy
import json
import unittest

import secure_ordinary_reconnect_trial as subject
from secure_weread_session import StoreError
from test_secure_native_session import Backend


def plan():
    baseline = dict(book_id='900001', chapter_uid='123', chapter_idx=3, chapter_offset=100,
                    raw_percent=12, summary='原有摘要')
    target = dict(baseline, chapter_offset=300, raw_percent=13, summary='下一页原文')
    result = {key: 'a'*64 for key in subject.HASHES}
    result.update(protocol=subject.PROTOCOL, baseline=baseline, target=target,
                  counts=dict(readingTime=100, recordReadingTime=99, ttsTime=0), version=0)
    return result


class OrdinaryReconnectStoreTests(unittest.TestCase):
    def setUp(self):
        self.backend = Backend()
        self.store = subject.OrdinaryReconnectStore(self.backend)

    def test_full_sequence_is_single_use_and_durable(self):
        receipt = self.store.reserve(plan())
        self.assertTrue(self.store.pending())
        for before, after in zip(subject.ORDER, subject.ORDER[1:]):
            receipt = self.store.advance(receipt, before, after)
            saved, readback = subject.OrdinaryReconnectStore(self.backend).read()
            self.assertEqual(saved['phase'], after)
            self.assertEqual(saved['posts'], subject.PHASES[after])
            self.assertEqual(readback, receipt)
        self.assertFalse(self.store.pending())
        with self.assertRaises(StoreError): self.store.reserve(plan())

    def test_unknown_send_cannot_be_replayed_or_jump_to_restore(self):
        receipt = self.store.reserve(plan())
        receipt = self.store.advance(receipt, 'prepared', 'enter_pending')
        for before, after in [('prepared', 'enter_pending'), ('enter_pending', 'restore_pending'),
                              ('enter_pending', 'position_pending'), ('enter_pending', 'retired')]:
            with self.subTest(before=before, after=after), self.assertRaises(StoreError):
                self.store.advance(receipt, before, after)
        self.assertEqual(self.store.read()[0]['phase'], 'enter_pending')
        self.assertTrue(self.store.pending())
        with self.assertRaises(StoreError): self.store.reserve(plan())

    def test_stale_receipt_and_corruption_fail_closed(self):
        stale = self.store.reserve(plan())
        current = self.store.advance(stale, 'prepared', 'enter_pending')
        with self.assertRaises(StoreError): self.store.advance(stale, 'enter_pending', 'enter_acknowledged')
        state = json.loads(self.backend.data)
        for key, bad in [('scope', 'elsewhere'), ('posts', 0), ('phase', 'retired'), ('schema', True)]:
            broken = copy.deepcopy(state); broken[key] = bad
            self.backend.data = json.dumps(broken).encode()
            with self.subTest(key=key), self.assertRaises(StoreError): self.store.read()
        self.backend.data = current.pending
        self.assertEqual(self.store.read()[0]['phase'], 'enter_pending')

    def test_rejects_unscoped_or_nonrestorable_plans(self):
        bad = []
        for key, value in [('summary', 'a'*21), ('summary', '\ud800'), ('chapter_offset', True), ('raw_percent', 12.5),
                           ('book_id', 'CB_synthetic'), ('chapter_uid', '0')]:
            item = plan(); item['baseline'][key] = value; bad.append(item)
        item = plan(); item['target']['chapter_uid'] = '124'; bad.append(item)
        item = plan(); item['target']['chapter_offset'] = item['baseline']['chapter_offset']; bad.append(item)
        item = plan(); item['counts']['readingTime'] = True; bad.append(item)
        item = plan(); item['source_sha256'] = 'fake'; bad.append(item)
        item = plan(); item['cookies'] = {'secret': 'unwanted'}; bad.append(item)
        for item in bad:
            with self.subTest(item=item), self.assertRaises(StoreError): self.store.reserve(item)
            self.assertIsNone(self.backend.data)

    def test_unconfirmed_keychain_write_fails_closed(self):
        class LostBackend(Backend):
            def save(self, data): pass
        store = subject.OrdinaryReconnectStore(LostBackend())
        with self.assertRaisesRegex(StoreError, 'ordinary_trial/readback'): store.reserve(plan())

    def test_retry_has_a_distinct_service_and_cannot_reset_original(self):
        first=subject.OrdinaryReconnectStore(Backend());retry=subject.OrdinaryReconnectRetryStore(Backend())
        self.assertNotEqual(first.service,retry.service);self.assertNotEqual(first.lock_name,retry.lock_name)
        first.reserve(plan());retry.reserve(plan())
        self.assertNotEqual(first.backend.data,retry.backend.data)
        with self.assertRaises(StoreError):first.reserve(plan())


if __name__ == '__main__': unittest.main()
