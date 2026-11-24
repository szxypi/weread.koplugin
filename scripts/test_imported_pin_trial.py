import unittest
from copy import deepcopy
from imported_pin_trial import request, run


class Intent:
    def __init__(self): self.state = None
    def read(self): return self.state, self.state
    def claim(self, plan):
        if self.state: raise ValueError('claimed')
        self.state = {'phase': 'claimed', 'plan': plan};return self.state
    def advance(self, receipt, phase):
        if receipt is not self.state: raise ValueError('replaced')
        self.state['phase'] = phase;return self.state


class ImportedPinTrialTest(unittest.TestCase):
    def setUp(self):
        self.shelf = {'books': [{'bookId': 'CB_abc', 'title': 'Synthetic', 'finishReading': 0, 'secret': 0}], 'archive': []}
        self.progress = {'book': {'bookId': 'CB_abc', 'chapterUid': 2, 'chapterIdx': 1,
                                  'chapterOffset': 4, 'progress': 15, 'updateTime': 10}}
        self.intents = {'pin': Intent(), 'restore': Intent()};self.sends = [];self.ack = True;self.change = None
    def observe(self, _target):
        value = {'native': deepcopy(self.shelf), 'web': deepcopy(self.shelf), 'progress': deepcopy(self.progress)}
        if self.change: self.change(value)
        return value
    def send(self, kind, body):
        self.sends.append(kind)
        if self.ack:
            if kind == 'pin': self.shelf['books'][0]['isTop'] = 1
            else: self.shelf['books'][0].pop('isTop', None)
            return {'succ': 1}
        return {}
    def execute(self, apply=True):
        return run('900000', 'CB_abc', 'a'*64, self.observe, self.send, self.intents, lambda: True, apply=apply)
    def test_success_and_no_replay(self):
        result = self.execute();self.assertEqual(result['result'], 'PASS');self.assertEqual(self.sends, ['pin', 'restore'])
        self.assertEqual(set(self.intents['pin'].state['plan']['baseline']), {'snapshot_hash', 'native_hash', 'web_hash', 'progress_hash'})
        self.assertEqual(self.execute()['result'], 'UNVERIFIED');self.assertEqual(self.sends, ['pin', 'restore'])
    def test_preview_never_writes(self):
        self.assertEqual(self.execute(False)['result'], 'READ_ONLY_PREVIEW');self.assertEqual(self.sends, [])
    def test_unknown_receipt_stops_and_does_not_restore(self):
        self.ack = False;self.assertEqual(self.execute()['result'], 'UNVERIFIED');self.assertEqual(self.sends, ['pin'])
        self.assertEqual(self.intents['pin'].state['phase'], 'claimed');self.assertIsNone(self.intents['restore'].state)
    def test_changed_unrelated_state_stops_restoration(self):
        def change(value):
            if self.sends: value['web']['books'][0]['secret'] = 1
        self.change = change;self.assertEqual(self.execute()['result'], 'UNVERIFIED');self.assertEqual(self.sends, ['pin'])
        self.assertIsNone(self.intents['restore'].state)
    def test_restore_with_no_effect_is_never_replayed(self):
        def send(kind, _body):
            self.sends.append(kind)
            if kind == 'pin': self.shelf['books'][0]['isTop'] = 1
            return {'succ': 1}
        result = run('900000', 'CB_abc', 'a'*64, self.observe, send, self.intents, lambda: True,
                     apply=True, sleep=lambda _delay: None)
        self.assertEqual(result['result'], 'UNVERIFIED');self.assertEqual(self.sends, ['pin', 'restore'])
        self.assertEqual(self.intents['restore'].state['phase'], 'acknowledged')
        self.execute();self.assertEqual(self.sends, ['pin', 'restore'])
    def test_changed_session_blocks_restoration(self):
        result = run('900000', 'CB_abc', 'a'*64, self.observe, self.send, self.intents,
                     lambda: not self.sends, apply=True, sleep=lambda _delay: None)
        self.assertEqual(result['result'], 'UNVERIFIED');self.assertEqual(self.sends, ['pin'])
        self.assertIsNone(self.intents['restore'].state)
    def test_rejects_invalid_ids(self):
        for ident in ('CB_', 'CB_x/y', '42', 'MP_WXS_2'):
            with self.subTest(ident=ident), self.assertRaises(ValueError): request(ident, True)


if __name__ == '__main__': unittest.main()
