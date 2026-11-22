import copy
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import ordinary_reconnect_broker as broker
from ordinary_reconnect_coordinator import Coordinator
from secure_ordinary_reconnect_trial import OrdinaryReconnectStore
from test_ordinary_reconnect_body_guard import body
from test_secure_native_session import Backend
from test_secure_ordinary_reconnect_trial import plan


class BrokerTests(unittest.TestCase):
    def setUp(self):
        self.plan = plan(); self.context = {'psvts': 'synthetic-ps', 'token': 'synthetic-token'}; self.pc = 'synthetic-pc'
        self.store = OrdinaryReconnectStore(Backend()); self.store.reserve(self.plan)
        self.events = []
        self.gate = Coordinator(self.store, self.plan, self.context, self.pc,
                                lambda stage, _p: self.events.append(('before', stage)) or True,
                                lambda stage, _p: self.events.append(('after', stage)) or True, armed=True)
        self.payload = dict(ordinary=True, armed=True, reconnect=True, ordinary_trial={'rpc_token': 'a'*32})
        self.first = body(self.plan, self.context, self.pc, 'enter')
        self.second = body(self.plan, self.context, self.pc, 'position')
        self.steps = [('STEP', dict(kind='claim', seq=1, body=self.first)),
                      ('STEP', dict(kind='ack', seq=1, status=200, response={'succ': 1})),
                      ('STEP', dict(kind='claim', seq=2, body=self.second)),
                      ('STEP', dict(kind='ack', seq=2, status=200, response={'succ': 1})),
                      ('RESULT', copy.deepcopy(broker.EXPECTED))]

    def run_broker(self, steps):
        fake = SimpleNamespace(stdin=object(), stdout=object(), wait=lambda timeout: 0)
        stream = SimpleNamespace(next=lambda: next(steps))
        report = {}
        with patch.object(broker.subprocess, 'Popen', return_value=fake), patch.object(broker, 'write_initial'), \
             patch.object(broker, 'Frames', return_value=stream), patch.object(broker, 'reply') as send, \
             patch.object(broker, 'stop') as stop:
            try: broker.execute(['fake-reader'], self.payload, self.gate, report)
            finally:
                self.sent = send.call_args_list
                stop.assert_called_once_with(fake)
                self.report = report
        return report

    def test_target_is_verified_before_restore_is_available(self):
        report = self.run_broker(iter(self.steps))
        self.assertEqual(report['result'], 'READER_POSITION_VERIFIED_RESTORE_PENDING')
        self.assertEqual((report['claimed_posts'], report['acknowledged_posts'], report['independently_verified']), (2, 2, 2))
        self.assertEqual(self.store.read()[0]['phase'], 'position_verified')
        self.assertEqual(self.events, [('before','enter'), ('after','enter'), ('before','position'), ('after','position')])
        self.assertEqual(len(self.sent), 4)

    def test_unknown_ack_stops_before_second_send(self):
        steps = copy.deepcopy(self.steps); steps[1][1]['response'] = {}
        with self.assertRaises(ValueError): self.run_broker(iter(steps))
        self.assertEqual(self.store.read()[0]['phase'], 'enter_pending')
        self.assertEqual((self.report['claimed_posts'], self.report['acknowledged_posts']), (1, 0))
        self.assertEqual(len(self.sent), 1)

    def test_independent_readback_failure_never_unblocks_next_send(self):
        self.gate.after = lambda *_: False
        with self.assertRaises(ValueError): self.run_broker(iter(self.steps))
        self.assertEqual(self.store.read()[0]['phase'], 'enter_acknowledged')
        self.assertEqual(len(self.sent), 1)

    def test_reordered_or_injected_frames_stop_without_a_send(self):
        for invalid in (dict(kind='claim', seq=2, body=self.second), dict(kind='claim', seq=1, body=self.first, extra=True),
                        dict(kind='ack', seq=1, status=200, response={'succ':1})):
            self.setUp()
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                self.run_broker(iter([('STEP', invalid)]))
            self.assertEqual(self.store.read()[0]['phase'], 'prepared')

    def test_false_result_does_not_authorize_restoration(self):
        steps = copy.deepcopy(self.steps); steps[-1][1]['fresh_process'] = False
        with self.assertRaises(ValueError): self.run_broker(iter(steps))
        self.assertEqual(self.store.read()[0]['phase'], 'position_verified')
        self.assertEqual(self.report['result'], 'UNVERIFIED')
        with self.assertRaises(ValueError):
            self.gate.claim('restore', body(self.plan, self.context, self.pc, 'restore'))


if __name__ == '__main__': unittest.main()
