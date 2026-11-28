"""The imported test fixture is changed only after stable independent reads."""
from copy import deepcopy
import unittest

from imported_started_ui_trial import initial, marked, plan, run


def snapshot():
    return dict(native={'secret': 0}, web={'secret': 0}, marks='empty', thoughts='empty',
                marks_empty=True, thoughts_empty=True, observed={'isStartReading': 0, 'startReadingTime': 0},
                progress={'flag': 0, 'start_time': 0, 'position': {'chapterUid': 0, 'chapterOffset': 0,
                    'progress': 0, 'readingTime': 0, 'recordReadingTime': 0, 'ttsTime': 0, 'summary': ''}})


class Tests(unittest.TestCase):
    def test_roundtrip_claims_proof_only_after_each_independent_read(self):
        state = snapshot();events = [];selection = {'target': 'CB_fixture'}
        def observe(): events.append('read');return deepcopy(state)
        def send(kind, action):
            events.append(kind);self.assertEqual(action, plan(selection, kind, state))
            state['progress'].update(flag=int(kind == 'mark'), start_time=123 if kind == 'mark' else 0)
            state['observed'].update(isStartReading=int(kind == 'mark'), startReadingTime=123 if kind == 'mark' else 0)
            return True
        def proof(kind, _selection, value): events.append(kind+'-proof');self.assertEqual(value, state)
        result = run(selection, observe, send, proof, lambda: True)
        self.assertEqual(result['result'], 'PASS');self.assertEqual(state, snapshot())
        self.assertEqual(events, ['read','read','mark','read','read','mark-proof',
                                  'restore','read','read','restore-proof'])

    def test_changed_unrelated_field_or_missing_status_stops_before_restore(self):
        for issue in ('counter', 'shelf', 'marks', 'stamp', 'extra_field'):
            state = snapshot();sent = []
            def send(kind, _action):
                sent.append(kind);state['progress'].update(flag=1, start_time=123)
                state['observed'].update(isStartReading=1, startReadingTime=123)
                if issue == 'counter': state['progress']['position']['readingTime'] = 1
                if issue == 'shelf': state['web']['secret'] = 1
                if issue == 'marks': state['marks'] = 'changed'
                if issue == 'stamp': state['progress']['start_time'] = 0
                if issue == 'extra_field': state['observed']['readUpdateTime'] = 1
                return True
            result = run({'target':'CB_fixture'}, lambda: deepcopy(state), send, lambda *_: None, lambda: True)
            with self.subTest(issue=issue):
                self.assertEqual(result['result'], 'UNVERIFIED');self.assertEqual(sent, ['mark'])

    def test_failed_native_receipt_never_starts_restore(self):
        sent = [];value = snapshot()
        result = run({'target':'CB_fixture'}, lambda: deepcopy(value),
                     lambda kind, _: sent.append(kind) or False, lambda *_: self.fail('proof'), lambda: True)
        self.assertEqual(result['result'], 'UNVERIFIED');self.assertEqual(sent, ['mark'])

    def test_inconsistent_baseline_or_nonempty_notes_never_dispatches(self):
        for issue in ('notes', 'position', 'missing_counter', 'unstable'):
            value = snapshot();count = [0];sent = []
            if issue == 'notes': value['marks_empty'] = False
            if issue == 'position': value['progress']['position']['chapterUid'] = 2
            if issue == 'missing_counter': value['progress']['position'].pop('ttsTime')
            def observe():
                count[0] += 1;result = deepcopy(value)
                if issue == 'unstable' and count[0] == 2: result['native']['secret'] = 1
                return result
            result = run({'target':'CB_fixture'}, observe, lambda kind, _: sent.append(kind), lambda *_: None, lambda: True)
            with self.subTest(issue=issue):
                self.assertEqual(result['result'], 'UNVERIFIED');self.assertEqual(sent, [])

    def test_false_and_true_start_checks_are_strict(self):
        value = snapshot();self.assertTrue(initial(value));other = deepcopy(value)
        other['progress'].update(flag=1,start_time=123);other['observed'].update(isStartReading=1,startReadingTime=123)
        self.assertTrue(marked(value, other));other['progress']['position']['progress'] = 1
        self.assertFalse(marked(value, other))


if __name__ == '__main__': unittest.main()
