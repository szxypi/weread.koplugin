import json
import unittest
from urllib.error import URLError

from ordinary_reconnect_coordinator import Coordinator
from ordinary_reconnect_restore import RestoreProbe, restore
from secure_ordinary_reconnect_trial import OrdinaryReconnectStore
from test_ordinary_reconnect_body_guard import body
from test_secure_native_session import Backend
from test_secure_ordinary_reconnect_trial import plan
from txt_full_summary import digest


class Response:
    status = 200
    def __init__(self, value): self.value = value
    def __enter__(self): return self
    def __exit__(self, *_): pass
    def read(self, _size): return json.dumps(self.value).encode()


class Opener:
    def __init__(self, value=None, fail=False):
        self.value = {'succ': 1} if value is None else value
        self.fail = fail; self.requests = []
    def open(self, request, timeout):
        self.requests.append(request)
        if self.fail: raise URLError('synthetic')
        return Response(self.value)


class RestoreTests(unittest.TestCase):
    def setUp(self):
        self.plan = plan(); self.plan['owner_sha256'] = digest('900000')
        self.context = dict(psvts='synthetic-ps', token='synthetic-token'); self.pc = 'synthetic-pc'
        self.store = OrdinaryReconnectStore(Backend()); self.store.reserve(self.plan)
        self.gate = Coordinator(self.store, self.plan, self.context, self.pc, lambda *_: True, lambda *_: True, armed=True)
        for stage in ('enter', 'position'):
            self.gate.claim(stage, body(self.plan, self.context, self.pc, stage))
            self.gate.ack(stage, 200, {'succ': 1}); self.gate.verify(stage)
        self.opener = Opener(); self.probe = RestoreProbe(opener=self.opener)
        self.probe.vid = '900000'; self.probe.book_id = '900001'; self.probe.authenticated = True
        self.probe.set_cookie('wr_vid', '900000'); self.probe.set_cookie('wr_skey', 'synthetic-cookie-session')
        self.addCleanup(self.probe.close)

    def test_one_exact_restore_then_independent_verification(self):
        report = {}; restore(self.probe, self.gate, lambda: True, report)
        self.assertEqual(report['result'], 'ORDINARY_RESTORATION_VERIFIED')
        self.assertEqual(self.store.read()[0]['phase'], 'retired')
        self.assertEqual(len(self.opener.requests), 1)
        sent = json.loads(self.opener.requests[0].data)
        self.assertEqual(sent['co'], self.plan['baseline']['chapter_offset'])
        self.assertEqual(sent['sm'], self.plan['baseline']['summary'])
        self.assertEqual(sent['pr'], self.plan['baseline']['raw_percent'])
        self.assertEqual(sent['rt'], 0)
        with self.assertRaises(ValueError): restore(self.probe, self.gate, lambda: True, {})
        self.assertEqual(len(self.opener.requests), 1)

    def test_unconfirmed_response_and_lost_connection_never_replay(self):
        for mode in ('noack', 'network'):
            self.setUp(); self.opener.value = {} if mode == 'noack' else {'succ': 1}; self.opener.fail = mode == 'network'
            report = {}
            with self.subTest(mode=mode), self.assertRaises(Exception): restore(self.probe, self.gate, lambda: True, report)
            self.assertEqual(self.store.read()[0]['phase'], 'restore_pending')
            self.assertEqual(self.gate.phase, 'stopped')
            self.assertEqual(len(self.opener.requests), 1)
            with self.assertRaises(ValueError): restore(self.probe, self.gate, lambda: True, {})
            self.assertEqual(len(self.opener.requests), 1)

    def test_failed_verification_stays_acknowledged_without_retry(self):
        self.gate.after = lambda *_: False
        with self.assertRaises(ValueError): restore(self.probe, self.gate, lambda: True, {})
        self.assertEqual(self.store.read()[0]['phase'], 'restore_acknowledged')
        self.assertEqual(self.gate.phase, 'stopped')
        self.assertEqual(len(self.opener.requests), 1)

    def test_scope_and_session_changes_block_dispatch(self):
        self.probe.vid = '900099'
        with self.assertRaises(ValueError): restore(self.probe, self.gate, lambda: True, {})
        self.assertEqual(self.store.read()[0]['phase'], 'position_verified')
        self.assertEqual(len(self.opener.requests), 0)
        self.probe.vid = '900000'; calls = iter([True, False])
        with self.assertRaises(ValueError): restore(self.probe, self.gate, lambda: next(calls), {})
        self.assertEqual(self.store.read()[0]['phase'], 'restore_pending')
        self.assertEqual(len(self.opener.requests), 0)

    def test_direct_transport_without_claim_is_rejected(self):
        candidate = body(self.plan, self.context, self.pc, 'restore')
        with self.assertRaises(ValueError): self.probe._send_once(candidate, self.gate, lambda: True)
        with self.assertRaises(ValueError): self.probe.request('write_restore', 'https://weread.qq.com/web/book/read', candidate)
        self.assertEqual(len(self.opener.requests), 0)


if __name__ == '__main__': unittest.main()
