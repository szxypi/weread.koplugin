import copy
import unittest

from cb_cloud_position import observed
from cb_fixture_position import LONG_SUMMARY, plan
from cb_initial_fixture_flow import run
from cb_initial_fixture_intent import Intent
from cb_initial_fixture_transport import ScopedProbe
from secure_weread_session import StoreError
from test_cb_fixture_position import fixture
from test_cb_fixture_position_transport import MemoryBackend


class Harness:
    def __init__(self, *, enter_moves=False, fail=None):
        book, sample = fixture()
        self.target = plan(book, sample)
        self.chapters = sample['chapters']
        self.current = dict(bookId=book, chapterUid=0, chapterIdx=0, chapterOffset=0,
                            progress=0, summary='', readingTime=0, recordReadingTime=0, ttsTime=0)
        self.enter_moves, self.fail = enter_moves, fail
        self.claimed, self.sent = [], []
        self.reads = 0
        self.mutate_after_claim = None

    def read(self):
        self.reads += 1
        raw = {'book': copy.deepcopy(self.current)}
        return {channel: observed(raw, self.target['book'], self.chapters, channel)
                for channel in ('native', 'web')}

    def claim(self, stage):
        order = ('write_enter', 'write_same')
        if len(self.claimed) >= len(order) or order[len(self.claimed)] != stage:
            raise ValueError('duplicate claim')
        self.claimed.append(stage)
        if self.mutate_after_claim == stage: self.current['readingTime'] = 1
        return len(self.claimed)

    def authorized(self, receipt):
        return receipt is None and not self.claimed or receipt == len(self.claimed)

    def send(self, stage, receipt):
        if not self.authorized(receipt): raise ValueError('stale receipt')
        self.sent.append(stage)
        if stage == 'same' or self.enter_moves:
            self.current.update(chapterUid=self.target['chapter'], chapterIdx=self.target['index'],
                                chapterOffset=self.target['first'], progress=self.target['percent'], summary=LONG_SUMMARY)
        return {} if self.fail == stage else {'succ': 1}

    def execute(self):
        return run(self.target, self.read, self.claim, self.authorized, self.send, sleep=lambda _: None)


class FirstPositionTest(unittest.TestCase):
    def test_enter_followed_by_first_position(self):
        h = Harness(); result = h.execute()
        self.assertEqual(h.sent, ['enter', 'same'])
        self.assertEqual(h.claimed, ['write_enter', 'write_same'])
        self.assertEqual(result['entry_effect'], 'original')
        self.assertTrue(result['cleanup_allowed'] and result['target_readback'])

    def test_enter_may_itself_establish_target(self):
        h = Harness(enter_moves=True); result = h.execute()
        self.assertEqual(h.sent, ['enter'])
        self.assertEqual(result['entry_effect'], 'target')
        self.assertTrue(result['cleanup_allowed'])

    def test_missing_ack_never_resends_or_allows_cleanup(self):
        for stage, sent in (('enter', ['enter']), ('same', ['enter', 'same'])):
            with self.subTest(stage=stage):
                h = Harness(fail=stage); result = h.execute()
                self.assertEqual(h.sent, sent)
                self.assertEqual(result['result'], 'UNVERIFIED')
                self.assertFalse(result['cleanup_allowed'])

    def test_initial_location_and_counter_must_be_explicit(self):
        for change in ({'chapterUid': 3}, {'readingTime': 1}, {'ttsTime': None}):
            h = Harness(); h.current.update(change)
            result = h.execute()
            self.assertEqual((result['writes'], h.claimed), (0, []))

    def test_change_after_claim_prevents_send(self):
        for stage, sent in (('write_enter', []), ('write_same', ['enter'])):
            h = Harness(); h.mutate_after_claim = stage
            result = h.execute()
            self.assertEqual(h.sent, sent)
            self.assertFalse(result['cleanup_allowed'])

    def test_mixed_channels_never_claim_or_send(self):
        h = Harness(); original = h.read
        def mismatched():
            values = original()
            values['web']['state']['kind'] = 'unavailable'
            return values
        result = run(h.target, mismatched, h.claim, h.authorized, h.send, sleep=lambda _: None)
        self.assertEqual((result['writes'], h.claimed), (0, []))

    def test_bad_summary_fails_after_position_without_cleanup(self):
        h = Harness(); send = h.send
        def bad_summary(stage, receipt):
            result = send(stage, receipt)
            if stage == 'same': h.current['summary'] = 'truncated'
            return result
        result = run(h.target, h.read, h.claim, h.authorized, bad_summary, sleep=lambda _: None)
        self.assertEqual(result['writes'], 2)
        self.assertFalse(result['cleanup_allowed'])

    def test_two_claims_are_durable_and_scope_cannot_be_reopened(self):
        backend = MemoryBackend(); intent = Intent(backend=backend)
        record = intent.reserve('900000', 'CB_SyntheticPosition', 'a' * 32, 'b' * 64)
        with self.assertRaises(StoreError): intent.claim(record, 'write_same')
        first = intent.claim(record, 'write_enter')
        self.assertTrue(intent.verify(record, first))
        second = intent.claim(record, 'write_same')
        self.assertFalse(intent.verify(record, first))
        self.assertTrue(intent.verify(record, second))
        for stage in ('write_enter', 'write_same', 'write_probe', 'write_restore'):
            with self.assertRaises(StoreError): intent.claim(record, stage)
        with self.assertRaises(StoreError): intent.reserve('900000', 'CB_SyntheticPosition', 'a' * 32, 'b' * 64)

    def test_transport_requires_current_durable_claim_and_owned_fixture(self):
        h = Harness(); backend = MemoryBackend(); intent = Intent(backend=backend)
        record = intent.reserve('900000', h.target['book'], 'a' * 32, 'b' * 64)
        class Sender(ScopedProbe):
            def request(self, stage, url, value=None, **_kwargs):
                self.guard(stage, url, value)
                return {'succ': 1}
        sender = Sender(h.target, '900000', lambda: True, intent, record)
        sender.authenticated = True; sender.set_cookie('wr_vid', '900000')
        with self.assertRaises(ValueError): sender.send_claimed('enter', b'forged')
        first = intent.claim(record, 'write_enter')
        self.assertEqual(sender.send_claimed('enter', first), {'succ': 1})
        with self.assertRaises(ValueError): sender.send_claimed('same', first)
        second = intent.claim(record, 'write_same')
        self.assertEqual(sender.send_claimed('same', second), {'succ': 1})
        with self.assertRaises(ValueError): sender.send_claimed('probe', second)
        denied = Sender(h.target, '900000', lambda: False, intent, record)
        denied.authenticated = True; denied.set_cookie('wr_vid', '900000'); denied.attempted = 1
        with self.assertRaises(ValueError): denied.send_claimed('same', second)


if __name__ == '__main__': unittest.main()
