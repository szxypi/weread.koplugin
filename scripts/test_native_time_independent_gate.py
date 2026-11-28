"""A fresh capture gets its own permanent, no-transport dispatch journal."""
from copy import deepcopy
import multiprocessing
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import native_time_independent_gate as task
from native_time_bundle_gate import DispatchGate
from secure_native_session import project_lock
from secure_weread_session import ACCOUNT,StoreError
from test_native_time_bundle_gate import FileBackend,fixture
from test_secure_native_session import Backend


class Capture:
    def __init__(self,bundle):self.bundle=deepcopy(bundle);self.receipt='immutable-synthetic-receipt'
    def read(self):return deepcopy(self.bundle),self.receipt


def competing(path,lock_path,bundle,grant,body,now,receipt,start,results):
    gate=task.IndependentGate(FileBackend(path),lambda:project_lock(Path(lock_path)),capture=Capture(bundle),
                              clock=lambda:now,zone=lambda:'+08:00')
    start.wait()
    try:
        gate.claim(receipt,bundle,grant,body,'synthetic-guest','synthetic-config');results.put('claimed')
    except (StoreError,ValueError):results.put('denied')


def claim_and_abort(path,lock_path,bundle,grant,body,now,receipt):
    gate=task.IndependentGate(FileBackend(path),lambda:project_lock(Path(lock_path)),capture=Capture(bundle),
                              clock=lambda:now,zone=lambda:'+08:00')
    gate.claim(receipt,bundle,grant,body,'synthetic-guest','synthetic-config')
    os._exit(17)


class IndependentGateTests(unittest.TestCase):
    def setup_gate(self):
        bundle,grant,body,now=fixture();capture=Capture(bundle);backend=Backend()
        gate=task.IndependentGate(backend,capture=capture,clock=lambda:now,zone=lambda:'+08:00')
        return bundle,grant,body,now,capture,backend,gate

    def test_one_permanent_claim_and_ack_without_transport(self):
        bundle,grant,body,_now,_capture,backend,gate=self.setup_gate()
        old_backend=Backend();old_gate=DispatchGate(old_backend,clock=lambda:bundle['plan']['not_before']+20,zone=lambda:'+08:00')
        self.assertEqual(old_gate.read(),(None,None));self.assertEqual(gate.read(),(None,None))
        self.assertIsInstance(gate.preview(bundle,grant,body,'synthetic-guest','synthetic-config'),str)
        prepared=gate.reserve(bundle,grant)
        claimed=gate.claim(prepared,bundle,grant,body,'synthetic-guest','synthetic-config')
        self.assertTrue(gate.assert_claim_current(claimed,bundle,grant,body,'synthetic-guest','synthetic-config'))
        with self.assertRaises(StoreError):gate.claim(prepared,bundle,grant,body,'synthetic-guest','synthetic-config')
        with self.assertRaises(StoreError):gate.reserve(bundle,grant)
        with self.assertRaises(ValueError):gate.acknowledge(claimed,{'succ':0})
        gate.acknowledge(claimed,{'succ':1})
        self.assertEqual(gate.read()[0]['phase'],'acknowledged')
        self.assertEqual(old_gate.read(),(None,None));self.assertIsNone(old_backend.load())
        self.assertIsNotNone(backend.load())
        for name in ('send','post','request','reset','delete'):
            self.assertFalse(hasattr(gate,name))

    def test_capture_or_receipt_change_stops_before_claim(self):
        for change in ('missing','changed','invalid_receipt','grant','request','zone'):
            bundle,grant,body,_now,capture,_backend,gate=self.setup_gate();prepared=gate.reserve(bundle,grant)
            if change=='missing':capture.receipt=None
            elif change=='changed':capture.bundle['plan']['seconds']+=1
            elif change=='invalid_receipt':prepared=None
            elif change=='grant':grant['accessToken']='different-synthetic'
            elif change=='request':body['signature']='different-synthetic'
            else:gate.zone=lambda:'+00:00'
            with self.subTest(change=change),self.assertRaises((StoreError,ValueError)):
                gate.claim(prepared,bundle,grant,body,'synthetic-guest','synthetic-config')
            self.assertEqual(gate.read()[0]['phase'],'prepared')

    def test_claimed_record_survives_reopen_and_never_replays(self):
        bundle,grant,body,now,capture,backend,gate=self.setup_gate()
        prepared=gate.reserve(bundle,grant);claimed=gate.claim(prepared,bundle,grant,body,'synthetic-guest','synthetic-config')
        reopened=task.IndependentGate(backend,capture=capture,clock=lambda:now,zone=lambda:'+08:00')
        self.assertEqual(reopened.read()[0]['phase'],'claimed')
        with self.assertRaises(StoreError):reopened.reserve(bundle,grant)
        with self.assertRaises(StoreError):reopened.claim(claimed,bundle,grant,body,'synthetic-guest','synthetic-config')
        capture.bundle['plan']['seconds']+=1
        with self.assertRaises(StoreError):reopened.assert_claim_current(claimed,bundle,grant,body,'synthetic-guest','synthetic-config')
        self.assertEqual(reopened.read()[0]['phase'],'claimed')

    def test_two_processes_cannot_claim_the_same_record(self):
        bundle,grant,body,now=fixture()
        with tempfile.TemporaryDirectory() as directory:
            path=str(Path(directory)/'gate.json');lock_path=str(Path(directory)/'gate.lock')
            gate=task.IndependentGate(FileBackend(path),lambda:project_lock(Path(lock_path)),capture=Capture(bundle),
                                      clock=lambda:now,zone=lambda:'+08:00')
            receipt=gate.reserve(bundle,grant);start=multiprocessing.Event();results=multiprocessing.Queue()
            children=[multiprocessing.Process(target=competing,args=(path,lock_path,bundle,grant,body,now,receipt,start,results)) for _ in range(2)]
            for child in children:child.start()
            start.set();observed=sorted(results.get(timeout=10) for _ in children)
            for child in children:child.join(10);self.assertEqual(child.exitcode,0)
            self.assertEqual(observed,['claimed','denied']);self.assertEqual(gate.read()[0]['phase'],'claimed')

    def test_abrupt_process_exit_after_claim_does_not_allow_replay(self):
        bundle,grant,body,now=fixture()
        with tempfile.TemporaryDirectory() as directory:
            path=str(Path(directory)/'gate.json');lock_path=str(Path(directory)/'gate.lock')
            gate=task.IndependentGate(FileBackend(path),lambda:project_lock(Path(lock_path)),capture=Capture(bundle),
                                      clock=lambda:now,zone=lambda:'+08:00')
            receipt=gate.reserve(bundle,grant)
            child=multiprocessing.Process(target=claim_and_abort,args=(path,lock_path,bundle,grant,body,now,receipt))
            child.start();child.join(10);self.assertEqual(child.exitcode,17)
            self.assertEqual(gate.read()[0]['phase'],'claimed')
            with self.assertRaises(StoreError):gate.reserve(bundle,grant)
            with self.assertRaises(StoreError):gate.claim(receipt,bundle,grant,body,'synthetic-guest','synthetic-config')

    def test_real_store_rejects_other_scopes_and_override(self):
        class FakeMac(Backend):
            def __init__(self,service=task.SERVICE,account=ACCOUNT):self.service=service;self.account=account;super().__init__()
        bundle,_grant,_body,_now=fixture()
        with patch.object(task,'MacKeychain',FakeMac),patch.object(task,'independent_capture',return_value=Capture(bundle)):
            with self.assertRaises(ValueError):task.IndependentGate(FakeMac('org.codex.weread.other'))
            with self.assertRaises(ValueError):task.IndependentGate(FakeMac(account='other'))
            with self.assertRaises(ValueError):task.IndependentGate(FakeMac(),capture=Capture(bundle))
            with self.assertRaises(ValueError):task.IndependentGate(FakeMac(),clock=lambda:1)
            gate=task.IndependentGate(FakeMac());gate.clock=lambda:1
            with self.assertRaises(ValueError):gate._wall_clock()


if __name__=='__main__':unittest.main()
