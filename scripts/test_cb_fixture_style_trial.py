"""Offline isolation, readback and dispatch tests for imported styles."""
from copy import deepcopy
import unittest
from unittest.mock import patch

from cb_fixture_style_trial import Intent, execute, prepare
from secure_weread_session import StoreError
from test_cb_fixture_highlight_trial import fixture
from test_secure_native_session import Backend
from verify_cb_fixture_style_trial import ScopedNative
from verify_eink_login import NativeProbe


class Fake:
    def __init__(self, baseline, body, fail=None):
        self.value = deepcopy(baseline); self.body = body; self.fail = fail; self.sent = []; self.valid = True

    def owned(self): return self.valid
    def read(self): return deepcopy(self.value)
    def send(self, phase, body, _receipt):
        self.sent.append(phase)
        if phase == 'create_pending':
            self.value['marks']['updated']['new'] = dict(body, bookmarkId='new')
        elif phase == 'delete_pending':
            assert body == {'bookmarkIds': ['new']}; del self.value['marks']['updated']['new']
        else:
            row = self.value['marks']['updated']['new']; assert body['bookmarkId'] == 'new'
            row['style'] = body['style']; row['colorStyle'] = body['colorStyle']
        if phase == self.fail: raise RuntimeError('unknown dispatch outcome')


def case(fail=None):
    sample, baseline, _, _ = fixture()
    plan, body = prepare('900000', sample['book_id'], 'a' * 32, sample, 1, baseline)
    fake = Fake(baseline, body, fail); intent = Intent(Backend())
    return plan, body, baseline, fake, intent


class StyleTrialTests(unittest.TestCase):
    def test_all_styles_and_restore(self):
        plan, body, baseline, fake, intent = case()
        result = execute(plan, body, baseline, intent, fake.owned, fake.read, fake.send)
        self.assertEqual(result['writes'], 4)
        self.assertEqual(fake.sent, ['create_pending', 'straight_pending', 'wave_pending', 'delete_pending'])
        self.assertEqual(fake.value, baseline); self.assertEqual(intent.read(), (None, None))

    def test_uncertain_step_never_replays(self):
        for phase in ('create_pending', 'straight_pending', 'wave_pending', 'delete_pending'):
            with self.subTest(phase=phase):
                plan, body, baseline, fake, intent = case(phase)
                with self.assertRaises(RuntimeError): execute(plan, body, baseline, intent, fake.owned, fake.read, fake.send)
                sent = list(fake.sent); self.assertEqual(intent.read()[0]['phase'], phase)
                with self.assertRaises((ValueError, StoreError)): execute(plan, body, baseline, intent, fake.owned, fake.read, fake.send)
                self.assertEqual(sent, fake.sent)

    def test_unrelated_change_stops(self):
        plan, body, baseline, fake, intent = case(); send = fake.send
        def alter(phase, payload, receipt):
            send(phase, payload, receipt); fake.value['thoughts']['other'] = {}
        with self.assertRaises(ValueError): execute(plan, body, baseline, intent, fake.owned, fake.read, alter)
        self.assertEqual(fake.sent, ['create_pending']); self.assertEqual(intent.read()[0]['phase'], 'create_pending')

    def test_transport_rejects_foreign_and_repeated_write(self):
        plan, body, _, fake, intent = case(); grant = {'vid': '900000', 'accessToken': 'synthetic'}
        native = ScopedNative(body['bookId'], grant, fake.owned, intent); native.body = body
        receipt = intent.reserve(plan)
        with patch.object(NativeProbe, 'request', return_value={'succ': 1}) as request:
            with self.assertRaises(ValueError): native.send('create_pending', dict(body, bookId='CB_other'), receipt, grant)
            native.send('create_pending', body, receipt, grant)
            with self.assertRaises(ValueError): native.send('create_pending', body, receipt, grant)
            with self.assertRaises(ValueError): native.send('straight_pending', {'bookmarkId': 'other', 'style': 0, 'colorStyle': 0}, receipt, grant)
            self.assertEqual(request.call_count, 1)


if __name__ == '__main__': unittest.main()
