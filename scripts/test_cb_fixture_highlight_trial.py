"""Offline guard and source tests; no real account or network."""
from copy import deepcopy
import hashlib
import unittest

from cb_fixture_highlight_trial import Intent, execute, prepare
from secure_weread_session import StoreError
from synthetic_upload_epub import TEXT
from test_secure_native_session import Backend


def fixture():
    book = 'CB_Synthetic42'; raw = '<html><body><p>' + TEXT + '</p></body></html>'
    sample = dict(book_id=book, chapter_uid='2', chapters=[{'chapterUid': 2}], source_format='web_xhtml',
                  source=raw, source_raw_sha256=hashlib.sha256(raw.encode()).hexdigest())
    baseline = dict(shelf={'fixture': True}, position={'chapter': '0'}, thoughts={},
                    marks=dict(updated={}, chapters={}))
    plan, body = prepare('900000', book, 'a' * 32, sample, 1, baseline)
    return sample, baseline, plan, body


class Fake:
    def __init__(self, baseline, body, fail=None):
        self.baseline = deepcopy(baseline); self.current = deepcopy(baseline)
        self.body = deepcopy(body); self.sent = []; self.fail = fail; self.valid = True

    def owned(self): return self.valid
    def read(self): return deepcopy(self.current)
    def send(self, phase, body, _receipt):
        self.sent.append(phase)
        if phase == 'create_pending':
            assert body == self.body
            row = dict(self.body, bookmarkId='new-synthetic-highlight')
            self.current['marks']['updated'][row['bookmarkId']] = row
        else:
            assert body == {'bookmarkIds': ['new-synthetic-highlight']}
            self.current['marks']['updated'].clear()
        if self.fail == phase: raise RuntimeError('unknown dispatch outcome')


class FixtureHighlightTests(unittest.TestCase):
    def test_exact_source_scope_and_request(self):
        sample, baseline, plan, body = fixture()
        self.assertEqual((body['type'], body['style'], body['markText']), (1, 1, TEXT))
        self.assertNotIn(sample['book_id'], str(plan)); self.assertNotIn(TEXT, str(plan))
        for modified in (dict(sample, book_id='CB_Other'), dict(sample, source=sample['source'] + TEXT),
                         dict(sample, source_raw_sha256='0' * 64), dict(sample, source_format='web_txt')):
            with self.subTest(modified=modified['source_format']), self.assertRaises(ValueError):
                prepare('900000', 'CB_Synthetic42', 'a' * 32, modified, 1, baseline)
        occupied = deepcopy(baseline); occupied['marks']['updated']['existing'] = {}
        with self.assertRaises(ValueError):prepare('900000', 'CB_Synthetic42', 'a' * 32, sample, 1, occupied)

    def test_two_writes_are_independently_checked_and_clear_reservation(self):
        _, baseline, plan, body = fixture(); fake = Fake(baseline, body); intent = Intent(Backend())
        result = execute(plan, body, baseline, intent, fake.owned, fake.read, fake.send)
        self.assertEqual(fake.sent, ['create_pending', 'delete_pending'])
        self.assertEqual(result['writes'], 2); self.assertEqual(intent.read(), (None, None))
        self.assertEqual(fake.current, baseline)

    def test_uncertain_dispatch_never_replays_or_cleans_up(self):
        for phase, expected in (('create_pending', ['create_pending']),
                                ('delete_pending', ['create_pending', 'delete_pending'])):
            _, baseline, plan, body = fixture(); fake = Fake(baseline, body, phase); intent = Intent(Backend())
            with self.subTest(phase=phase), self.assertRaises(RuntimeError):
                execute(plan, body, baseline, intent, fake.owned, fake.read, fake.send)
            self.assertEqual(fake.sent, expected); self.assertEqual(intent.read()[0]['phase'], phase)
            with self.assertRaises((StoreError, ValueError)):
                execute(plan, body, baseline, intent, fake.owned, fake.read, fake.send)
            self.assertEqual(fake.sent, expected)

    def test_changed_baseline_or_unowned_fixture_never_dispatches(self):
        _, baseline, plan, body = fixture(); fake = Fake(baseline, body); intent = Intent(Backend())
        fake.valid = False
        with self.assertRaises(ValueError):execute(plan, body, baseline, intent, fake.owned, fake.read, fake.send)
        fake.valid = True; fake.current['position']['chapter'] = '1'
        with self.assertRaises(ValueError):execute(plan, body, baseline, intent, fake.owned, fake.read, fake.send)
        self.assertEqual(fake.sent, []); self.assertEqual(intent.read(), (None, None))

    def test_unrelated_mutation_after_create_stops_before_delete(self):
        _, baseline, plan, body = fixture(); fake = Fake(baseline, body); intent = Intent(Backend())
        original = fake.send
        def send(phase, value, receipt):
            original(phase, value, receipt)
            fake.current['thoughts']['unexpected'] = {}
        with self.assertRaises(ValueError):execute(plan, body, baseline, intent, fake.owned, fake.read, send)
        self.assertEqual(fake.sent, ['create_pending']); self.assertEqual(intent.read()[0]['phase'], 'create_pending')


if __name__ == '__main__':unittest.main()
