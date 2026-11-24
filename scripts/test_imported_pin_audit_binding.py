import json
import unittest
from copy import deepcopy

from imported_pin_audit_binding import create, permits
from imported_pin_trial import request
from personal_upload_trial import hash_value


class Memory:
    def __init__(self): self.value = None
    def load(self): return self.value
    def save(self, value): self.value = value


class BindingTest(unittest.TestCase):
    def setUp(self):
        self.grant = {'vid': '900000', 'accessToken': 'old', 'refreshToken': 'refresh', 'deviceId': 'synthetic-device'}
        selection = {'owner': '900000', 'book_id': 'CB_abc', 'grant_hash': hash_value(self.grant)}
        def record(kind):
            return {'schema': 1, 'scope': 'test', 'attempt': kind, 'claimed_at': 123,
                    'plan': {'selection': deepcopy(selection), 'record': {'kind': kind},
                             'body': request('CB_abc', kind == 'pin'), 'baseline': {'snapshot_hash': 'a'*64}}}
        self.pin = record('pin');self.restore = record('restore');self.backend = Memory()
    def test_same_device_new_token_can_only_inspect(self):
        self.assertTrue(create('900000', self.grant, self.pin, self.restore, self.backend))
        renewed = dict(self.grant, accessToken='new', refreshToken='new-refresh')
        self.assertTrue(permits('900000', renewed, self.pin, self.restore, self.backend))
        self.assertNotIn(b'old', self.backend.value);self.assertNotIn(b'synthetic-device', self.backend.value)
        self.assertNotIn(b'CB_abc', self.backend.value)
    def test_changed_device_account_or_record_rejected(self):
        create('900000', self.grant, self.pin, self.restore, self.backend)
        self.assertFalse(permits('900000', dict(self.grant, deviceId='other'), self.pin, self.restore, self.backend))
        self.assertFalse(permits('900001', self.grant, self.pin, self.restore, self.backend))
        altered = deepcopy(self.restore);altered['plan']['body']['isDel'] = 0
        self.assertFalse(permits('900000', self.grant, self.pin, altered, self.backend))
        self.backend.value = json.dumps({'schema': 1}).encode()
        self.assertFalse(permits('900000', self.grant, self.pin, self.restore, self.backend))
    def test_cannot_bind_with_new_credential_or_replace_binding(self):
        with self.assertRaises(ValueError): create('900000', dict(self.grant, accessToken='new'), self.pin, self.restore, self.backend)
        create('900000', self.grant, self.pin, self.restore, self.backend)
        self.restore['attempt'] = 'changed'
        with self.assertRaises(ValueError): create('900000', self.grant, self.pin, self.restore, self.backend)


if __name__ == '__main__': unittest.main()
