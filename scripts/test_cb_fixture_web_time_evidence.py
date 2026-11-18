"""The pre-dispatch baseline is durable and cannot be overwritten."""
import copy
import unittest
from cb_fixture_web_time_evidence import Evidence
from secure_weread_session import StoreError
from test_cb_fixture_position_transport import MemoryBackend


def sample():
    return dict(schema=1,owner_sha256='a'*64,book_sha256='b'*64,attempt='c'*32,
                baseline=dict(source='d'*64,position={},updated_at=123,counters={},stats={},body={}))


class TestEvidence(unittest.TestCase):
    def test_readback_and_no_overwrite(self):
        backend=MemoryBackend();store=Evidence(backend=backend);value=sample();receipt=store.save(value)
        self.assertEqual(backend.load(),receipt)
        with self.assertRaises(StoreError):store.save(value)
    def test_missing_extra_and_bad_scope_rejected(self):
        for key in ('owner_sha256','book_sha256','attempt','baseline'):
            value=sample();del value[key]
            with self.subTest(key=key),self.assertRaises(StoreError):Evidence(backend=MemoryBackend()).save(value)
        for mutation in ({'owner_sha256':'bad'},{'attempt':'bad'},{'schema':True},{'extra':1}):
            value=sample();value.update(mutation)
            with self.subTest(mutation=mutation),self.assertRaises(StoreError):Evidence(backend=MemoryBackend()).save(value)
        value=copy.deepcopy(sample());value['baseline']['extra']='bad'
        with self.assertRaises(StoreError):Evidence(backend=MemoryBackend()).save(value)
    def test_oversized_snapshot_rejected(self):
        value=sample();value['baseline']['stats']={'synthetic':'x'*70000}
        with self.assertRaises(StoreError):Evidence(backend=MemoryBackend()).save(value)


if __name__=='__main__':unittest.main()
