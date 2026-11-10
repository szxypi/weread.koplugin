"""Validate crash barriers and isolated Linux session termination without an account."""
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile
import threading
import unittest

from fetch_weread_epub import weread_e
from mock_weread import BOOK_ID
from process_loss_runtime import ProcessLossServer, enable_subreaper, kill_reader_session, session_members, wait_boundary


class BarrierTests(unittest.TestCase):
    def setUp(self):
        self.server = ProcessLossServer(0, None, 'after-apply')
        self.body = dict(b=weread_e(BOOK_ID), c=weread_e(2), ci=2, co=123, pr=25, sm='synthetic', rt=30)

    def tearDown(self):
        self.server.release.set()
        self.server.server_close()

    def arm(self):
        return self.server.route('POST', 'http://127.0.0.1/__process_loss_arm', {'case': self.server.case, 'kind': self.server.kind})

    def test_apply_is_observed_before_releasing_the_receipt(self):
        self.arm()
        returned = []
        thread = threading.Thread(target=lambda: returned.append(
            self.server.route('POST', 'https://weread.qq.com/web/book/read', self.body)))
        thread.start()
        try:
            self.assertTrue(self.server.blocked.wait(2))
            self.assertEqual(returned, [])
            self.assertEqual(self.server.get_progress(BOOK_ID)['book']['chapterOffset'], 123)
            self.assertEqual(len(self.server.read_bodies), 1)
        finally:
            self.server.release.set()
            thread.join(2)
        self.assertEqual(returned, [(200, {'succ': 1})])
        self.assertEqual(len(self.server.read_bodies), 1)

    def test_readback_barrier_is_after_an_acknowledged_report(self):
        self.server.case = 'before-readback'
        self.arm()
        self.assertEqual(self.server.route('GET', 'https://weread.qq.com/web/book/getProgress', {})[0], 200)
        self.assertFalse(self.server.blocked.is_set())
        self.assertEqual(self.server.route('POST', 'https://weread.qq.com/web/book/read', self.body), (200, {'succ': 1}))
        self.assertFalse(self.server.blocked.is_set())
        returned = []
        thread = threading.Thread(target=lambda: returned.append(
            self.server.route('GET', 'https://weread.qq.com/web/book/getProgress', {})))
        thread.start()
        try:
            self.assertTrue(self.server.blocked.wait(2))
            self.assertEqual(returned, [])
        finally:
            self.server.release.set()
            thread.join(2)
        self.assertEqual(returned[0][1]['book']['chapterOffset'], 123)

    def test_barrier_rejects_another_case_rearming_and_wrong_method(self):
        for method, body in [('GET', {'case': 'after-apply', 'kind': 'periodic'}),
                             ('POST', {'case': 'before-dispatch', 'kind': 'periodic'}),
                             ('POST', {'case': 'after-apply', 'kind': 'close'}),
                             ('POST', {'case': 'after-apply', 'kind': 'periodic', 'extra': True})]:
            with self.assertRaises(ValueError):
                self.server.route(method, 'http://127.0.0.1/__process_loss_arm', body)
        self.assertFalse(self.server.armed)
        self.arm()
        with self.assertRaises(ValueError):
            self.arm()
        with self.assertRaises(ValueError):
            ProcessLossServer(0, None, 'unknown')
        with self.assertRaises(ValueError):
            ProcessLossServer(0, None, 'after-apply', 'unknown')


@unittest.skipUnless(sys.platform == 'linux', 'requires Linux /proc and child subreaping')
class SupervisorTests(unittest.TestCase):
    def test_kills_and_reaps_worker_group_without_touching_another_session(self):
        enable_subreaper()
        other = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'], start_new_session=True)
        program = ('import os,time\nchild=os.fork()\n'
                   'if child==0:\n os.setpgid(0,0)\n time.sleep(60)\n os._exit(0)\n'
                   'print(child,flush=True)\ntime.sleep(60)\n')
        reader = subprocess.Popen([sys.executable, '-c', program], start_new_session=True,
                                  stdout=subprocess.PIPE, text=True)
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(reader.stdout, selectors.EVENT_READ)
                self.assertTrue(selector.select(5), 'fixture did not fork its worker')
                child = int(reader.stdout.readline())
            killed = kill_reader_session(reader)
            self.assertIn(child, killed)
            self.assertIn(reader.pid, killed)
            self.assertEqual(reader.returncode, -9)
            self.assertEqual(session_members(reader.pid), [])
            self.assertIsNone(other.poll())
        finally:
            if reader.poll() is None:
                kill_reader_session(reader)
            reader.stdout.close()
            other.terminate(); other.wait(timeout=5)

    def test_refuses_a_process_in_the_supervisors_session(self):
        reader = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
        try:
            with self.assertRaisesRegex(RuntimeError, 'own isolated session'):
                kill_reader_session(reader)
            self.assertIsNone(reader.poll())
        finally:
            reader.terminate(); reader.wait(timeout=5)

    def test_terminal_reader_and_foreign_barrier_are_not_restarted(self):
        enable_subreaper()
        exited = subprocess.Popen([sys.executable, '-c', 'pass'], start_new_session=True)
        exited.wait(timeout=5)
        with self.assertRaisesRegex(RuntimeError, 'exited before'):
            kill_reader_session(exited)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'evidence').mkdir()
            (root / 'evidence/process-loss-ready.json').write_text(json.dumps(
                dict(parent_pid=os.getpid(), case='after-apply', kind='periodic')))
            reader = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'], start_new_session=True)
            try:
                server = type('Barrier', (), {'case': 'after-apply', 'kind': 'periodic'})()
                with self.assertRaisesRegex(RuntimeError, 'another reader'):
                    wait_boundary(reader, root, server, timeout=1)
                with self.assertRaisesRegex(RuntimeError, 'exited before'):
                    wait_boundary(exited, root, server, timeout=1)
            finally:
                kill_reader_session(reader)


if __name__ == '__main__':
    unittest.main()
