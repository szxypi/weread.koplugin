"""Bounded prewrite recovery evidence and independent loopback refresh checks."""
from copy import deepcopy
import hashlib
import json
import time
import unittest
from types import SimpleNamespace
from native_source_recovery_fixture import NativeRecoveryServer, MODES, GRANT, BOOK_ID
from run_native_reader_recovery import decode, check_server, FRAME, FLAGS, RECOVERY_FLAGS, SUCCESS, CANCELLED
from test_native_reader_position import wire


def stage(kind):
    success = kind in SUCCESS
    pending = kind in (*CANCELLED, 'unknown', 'foreign')
    flags = {key: key in ('manual', 'original_local_units', 'summary_not_in_checkpoints',
                         'parent_only_document', 'workers_reaped', 'reader_from_shelf', 'source_workers') for key in FLAGS}
    detail = {key: False for key in RECOVERY_FLAGS}
    detail.update(kind=kind, confirmed=success, fresh_source=success, closed=kind.startswith('close-'),
                  cancelled=kind in CANCELLED, save_only=kind in ('save', 'save-sync'), timer_triggered=kind.startswith('timer-'),
                  unknown_not_replayed=kind == 'post', local_kept=not success and kind != 'post',
                  renewal_pending=pending, no_closed_document_calls=True, workers_reaped=True,
                  grant_revision=1 if kind == 'post' else 2 if pending else 3,
                  source_passes=1 if pending or kind == 'post' else 2,
                  auth_posts=int(kind != 'post'), expired_responses=2 if kind == 'second' else 1, failed_line=0)
    return dict(result='PASS', phase='complete', failed_line=0, native_posts=2 if success or kind == 'post' else 1,
                web_posts=0, recovery_case=detail, **flags)


def frame(value):
    return FRAME + json.dumps(value).encode()


def refresh():
    timestamp, random = int(time.time() * 1000), 123
    return dict(deviceId=GRANT['deviceId'], deviceName='BOOX', deviceType=3, timestamp=timestamp,
                random=random, trackId='', refreshToken=GRANT['refreshToken'], inBackground=0, kickType=1,
                refCgi='', signature=hashlib.sha256(f"{timestamp}{GRANT['deviceId']}{random}".encode()).hexdigest())


class RecoveryProofTests(unittest.TestCase):
    def test_all_modes_have_distinct_closed_proofs(self):
        for kind in MODES:
            with self.subTest(kind=kind):
                self.assertEqual(decode(frame(stage(kind)), kind), stage(kind))

    def test_success_requires_fresh_source_exact_revision_and_one_auth(self):
        for kind in SUCCESS:
            for key, bad in (('confirmed', False), ('fresh_source', False), ('source_passes', 1),
                             ('auth_posts', 0), ('grant_revision', 2), ('renewal_pending', True),
                             ('no_closed_document_calls', False), ('workers_reaped', False)):
                value = stage(kind); value['recovery_case'][key] = bad
                with self.subTest(kind=kind, key=key), self.assertRaises(ValueError):
                    decode(frame(value), kind)

    def test_unknown_data_receipt_never_renews_or_claims_success(self):
        for key, bad in (('auth_posts', 1), ('confirmed', True), ('source_passes', 2),
                         ('unknown_not_replayed', False), ('grant_revision', 3)):
            value = stage('post'); value['recovery_case'][key] = bad
            with self.assertRaises(ValueError): decode(frame(value), 'post')

    def test_second_expiry_never_repeats_renewal(self):
        for key, bad in (('auth_posts', 2), ('expired_responses', 1), ('confirmed', True), ('local_kept', False)):
            value = stage('second'); value['recovery_case'][key] = bad
            with self.assertRaises(ValueError): decode(frame(value), 'second')

    def test_cancelled_or_unknown_grant_remains_pending(self):
        for kind in ('cancel', 'unknown', 'foreign'):
            for key, bad in (('renewal_pending', False), ('grant_revision', 3), ('source_passes', 2)):
                value = stage(kind); value['recovery_case'][key] = bad
                with self.assertRaises(ValueError): decode(frame(value), kind)

    def test_private_extras_types_and_ambiguous_frames_rejected(self):
        for nested in (False, True):
            value = stage('save-sync'); (value['recovery_case'] if nested else value)['summary'] = 'private'
            with self.assertRaises(ValueError): decode(frame(value), 'save-sync')
        for key, bad in (('auth_posts', True), ('confirmed', 1), ('kind', 'other')):
            value = stage('snapshot'); value['recovery_case'][key] = bad
            with self.assertRaises(ValueError): decode(frame(value), 'snapshot')
        for raw in (b'private', FRAME + frame(stage('snapshot')), b'x' * (2 * 1024 * 1024 + 1)):
            with self.assertRaises(ValueError): decode(raw, 'snapshot')

    def test_unverified_never_promoted_to_pass(self):
        value = stage('snapshot'); value['result'] = 'UNVERIFIED'; value['recovery_case']['confirmed'] = False
        self.assertEqual(decode(frame(value), 'snapshot')['result'], 'UNVERIFIED')

    def test_server_counts_must_independently_match_child(self):
        value = stage('snapshot')
        server = SimpleNamespace(native_posts=2, auth_posts=1, expiries=1, preserved_counts=lambda: True)
        check_server(server, value, 'snapshot')
        for key, bad in (('native_posts', 1), ('auth_posts', 0), ('auth_posts', 2), ('expiries', 2),
                         ('preserved_counts', lambda: False)):
            changed = deepcopy(server); setattr(changed, key, bad)
            with self.assertRaises(ValueError): check_server(changed, value, 'snapshot')


class RecoveryFixtureTests(unittest.TestCase):
    def setUp(self): self.server = NativeRecoveryServer()
    def tearDown(self): self.server.server_close()
    def control(self, kind):
        return self.server.route('POST', 'https://weread.qq.com/mock/native-recovery', {'mode': kind})
    def login(self, value=None):
        return self.server.route('POST', 'https://i.weread.qq.com/login', value if value is not None else refresh())
    def info(self):
        return self.server.route('GET', 'https://i.weread.qq.com/book/info?bookId=' + BOOK_ID, {})

    def test_refresh_retains_missing_refresh_token_and_never_changes_counters(self):
        self.control('snapshot'); before = self.server.snapshot()
        self.assertEqual(self.info()[0], 401)
        status, value = self.login()
        self.assertEqual((status, value), (200, dict(vid=900000, accessToken='synthetic-renewed-access')))
        self.assertEqual(self.server.snapshot(), before)
        self.assertTrue(self.server.preserved_counts())
        self.assertEqual(self.server.native_posts, 0)
        with self.assertRaises(ValueError): self.login()

    def test_prewrite_and_second_expiry_have_exact_read_boundaries(self):
        self.control('prewrite')
        self.assertEqual(self.info()[0], 200); self.assertEqual(self.info()[0], 401)
        self.login(); self.assertEqual(self.info()[0], 200)
        self.assertEqual(self.server.expiries, 1)

    def test_second_expiry_after_one_auth(self):
        self.control('second'); self.assertEqual(self.info()[0], 401); self.login()
        self.assertEqual(self.info()[0], 401); self.assertEqual(self.info()[0], 200)
        self.assertEqual((self.server.auth_posts, self.server.expiries, self.server.native_posts), (1, 2, 0))

    def test_full_signed_refresh_dto_is_independently_validated(self):
        changes = ({'extra': 'private'}, {'signature': '0' * 64}, {'deviceId': '2' * 32},
                   {'refreshToken': 'wrong'}, {'timestamp': 1}, {'random': True}, {'deviceType': 2})
        self.control('snapshot')
        for change in changes:
            self.server.auth_posts = 0
            value = refresh(); value.update(change)
            with self.subTest(change=change), self.assertRaises(ValueError): self.login(value)
        self.assertEqual(self.server.native_posts, 0)

    def test_lost_data_receipt_applies_once_and_never_becomes_auth_expiry(self):
        self.control('post')
        self.assertEqual(self.server.route('POST', 'https://i.weread.qq.com/book/read', wire())[0], 401)
        self.assertEqual((self.server.auth_posts, self.server.native_posts, self.server.expiries), (0, 1, 1))
        self.assertEqual(self.server.snapshot()['book']['chapterOffset'], 121)
        self.assertTrue(self.server.preserved_counts())

    def test_control_cannot_be_rearmed(self):
        self.control('snapshot')
        with self.assertRaises(ValueError): self.control('prewrite')


if __name__ == '__main__': unittest.main()
