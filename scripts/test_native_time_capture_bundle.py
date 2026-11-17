"""Immutable, isolated capture evidence and partial-save safeguards."""
import unittest
from unittest.mock import patch

from native_time_capture_bundle import CaptureBundleStore, SERVICE
from secure_weread_session import StoreError
from test_native_time_capture import large_capture
from test_native_time_capture_evidence import make_fixture, bundle
from test_secure_native_session import Backend


def fixture():
    _p,ledger,coverage=make_fixture();plan=large_capture();proof=bundle(ledger,coverage)
    ledger.close();coverage.close()
    parts={}
    def chunks(index):return parts.setdefault(index,Backend())
    return plan,proof,CaptureBundleStore(Backend(),chunks=chunks),parts,chunks


class CaptureBundleTests(unittest.TestCase):
    def test_roundtrip_reopen_preserves_exact_complete_bundle(self):
        plan,proof,store,parts,chunks=fixture();receipt=store.capture(plan,proof)
        reopened=CaptureBundleStore(store.backend,chunks=chunks)
        saved,again=reopened.read()
        self.assertEqual(saved,{'plan':plan,'evidence':proof});self.assertEqual(again.raw,receipt.raw)
        self.assertGreater(sum(part.data is not None for part in parts.values()),1)
        with self.assertRaises(StoreError):store.capture(plan,proof)
        self.assertNotEqual(SERVICE,'org.codex.weread.goal-native-statistics-time-capture-v1')
        for method in ('claim','send','advance','delete','renew'):self.assertFalse(hasattr(store,method))

    def test_invalid_plan_or_evidence_never_writes(self):
        plan,proof,store,parts,_=fixture();proof['coverage_sha256']='0'*64
        with self.assertRaises(ValueError):store.capture(plan,proof)
        self.assertIsNone(store.backend.data);self.assertTrue(all(p.data is None for p in parts.values()))

    def test_partial_save_is_never_overwritten(self):
        plan,proof,store,parts,_=fixture()
        with patch.object(store.chunks(2),'save',side_effect=StoreError('synthetic')):
            with self.assertRaises(StoreError):store.capture(plan,proof)
        self.assertIsNone(store.backend.data);self.assertIsNotNone(parts[1].data)
        with self.assertRaises(StoreError):store.read()
        with self.assertRaises(StoreError):store.capture(plan,proof)

    def test_missing_corrupt_or_reordered_parts_fail_closed(self):
        for mode in ('missing','corrupt','manifest','extra'):
            plan,proof,store,parts,_=fixture();store.capture(plan,proof)
            if mode=='missing':parts[1].data=None
            elif mode=='corrupt':parts[1].data=b'corrupt'
            elif mode=='manifest':store.backend.data=b'{}'
            else:parts[max(index for index,part in parts.items() if part.data is not None)+1].data=b'unexpected'
            with self.subTest(mode=mode),self.assertRaises(StoreError):store.read()

    def test_manifest_failure_keeps_parts_and_refuses_retry(self):
        plan,proof,store,parts,_=fixture()
        with patch.object(store.backend,'save',side_effect=StoreError('synthetic')):
            with self.assertRaises(StoreError):store.capture(plan,proof)
        self.assertIsNotNone(parts[1].data)
        with self.assertRaises(StoreError):store.capture(plan,proof)


if __name__=='__main__':unittest.main()
