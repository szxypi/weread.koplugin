import copy
from contextlib import redirect_stdout
import io
import json
import unittest
from unittest.mock import patch

from cb_fixture_position import LONG_SUMMARY
from cb_initial_fixture_intent import Intent
from cb_initial_fixture_transport import ScopedProbe
from test_cb_fixture_position import fixture
from test_cb_fixture_position_transport import MemoryBackend
from test_cloud_group_contract import shelf
import verify_cb_initial_fixture_trial as task


class Backend:
    def __init__(self, fail=None, changed_source=False):
        self.book, self.sample = fixture(); self.sample['source_raw_sha256'] = 'f' * 64
        self.owner = '900000'; self.imported = False; self.fail = fail; self.sent = []
        self.current = dict(bookId=self.book, chapterUid=0, chapterIdx=0, chapterOffset=0,
                            progress=0, summary='', readingTime=0, recordReadingTime=0, ttsTime=0)
        self.receipt = object(); self.cleanup = False
        self.changed_source, self.source_reads = changed_source, 0
        self.state = dict(phase='imported', target=self.book, attempt='a' * 32, plan=dict(owner=self.owner))

    def read(self): return (self.state, self.receipt) if self.imported else (None, None)


def run_case(fail=None, apply=True, changed_source=False):
    backend = Backend(fail, changed_source); grant = {'vid': backend.owner}
    saved = dict(vid=backend.owner, cookies={'wr_vid': backend.owner, 'wr_skey': 'synthetic'})
    intent = Intent(backend=MemoryBackend())

    class NativeStore:
        def load(self, _owner): return grant

    class BaseWeb:
        def __init__(self): self.authenticated = False; self.samples = []; self.book_id = None
        def set_cookie(self, *_): pass
        def verify_account(self): self.authenticated = True
        def close(self): pass

    class Web(BaseWeb):
        def request(self, stage, _url):
            assert stage == 'shelf'
            value = shelf()
            if backend.imported: value['books'].append(dict(bookId=backend.book, title='test', finishReading=0, secret=0))
            return value

    class Source(BaseWeb):
        def __init__(self):
            super().__init__(); self.allowed = set()
            self.last_checks = dict(catalog_unchanged=True, versions_unchanged=True, position_unchanged=True)
        def inspect(self, target):
            assert target == backend.book and target in self.allowed
            backend.source_reads += 1
            value = copy.deepcopy(backend.sample)
            if backend.changed_source and backend.source_reads > 1: value['source_raw_sha256'] = 'e' * 64
            return value

    class Native:
        def __init__(self, _grant, target): assert target == backend.book
        def request(self, *_args, **_kwargs): return {'book': copy.deepcopy(backend.current)}

    class Sender(ScopedProbe):
        def verify_account(self): self.authenticated = True
        def request(self, stage, url, value=None, **_kwargs):
            self.guard(stage, url, value)
            if stage == 'progress_after': return {'book': copy.deepcopy(backend.current)}
            backend.sent.append(stage)
            if stage == 'same':
                backend.current.update(chapterUid=self.plan['chapter'], chapterIdx=self.plan['index'],
                                       chapterOffset=self.plan['first'], progress=self.plan['percent'], summary=LONG_SUMMARY)
            return {} if backend.fail == stage else {'succ': 1}

    def uploader(_probe, _journal, _grant, _check, source, *, apply, cleanup_gate):
        if not apply: return dict(result='READ_ONLY_PREVIEW', phase='preview')
        backend.imported = True
        assert source(backend.book)
        backend.cleanup = cleanup_gate(backend, backend.receipt, backend.state['plan'], backend.book)
        if backend.cleanup: backend.imported = False
        return dict(result='EPUB_IMPORT_AND_SOURCE_VERIFIED' if backend.cleanup else 'UNVERIFIED',
                    phase='restored' if backend.cleanup else 'imported', cos_put_attempts=1,
                    notify_posts=1, cleanup_posts=int(backend.cleanup))

    with patch.object(task, 'WebSourceProbe', Web), patch.object(task, 'CbReadingProbe', Source), \
         patch.object(task, 'NativeRead', Native), patch.object(task, 'ScopedProbe', Sender), \
         patch.object(task, 'save_refreshed_web_session', return_value=False):
        result = task.run(saved, None, NativeStore(), grant, backend, intent, apply=apply,
                          upload_factory=lambda *_: None, uploader=uploader, sleeper=lambda _: None)
    return result, backend, intent


class TrialTest(unittest.TestCase):
    def test_default_offline_does_not_load_session(self):
        with patch.object(task, 'SessionStore') as store, redirect_stdout(io.StringIO()) as output:
            self.assertEqual(task.main([]), 0)
        store.assert_not_called(); self.assertEqual(json.loads(output.getvalue())['result'], 'OFFLINE_ONLY')

    def test_complete_trial_verifies_then_removes_only_fixture(self):
        result, backend, _intent = run_case()
        self.assertEqual(result['result'], 'CB_INITIAL_FIXTURE_VERIFIED')
        self.assertEqual(backend.sent, ['enter', 'same'])
        self.assertTrue(backend.cleanup and not backend.imported and result['web_shelf_restored'])
        self.assertEqual(result['account_data_writes_known'], 5)
        self.assertNotIn(backend.book, json.dumps(result))

    def test_unknown_receipt_keeps_fixture_and_prevents_replay(self):
        for stage in ('enter', 'same'):
            result, backend, intent = run_case(stage)
            self.assertEqual(result['result'], 'UNVERIFIED')
            self.assertTrue(backend.imported and not backend.cleanup)
            self.assertIsNotNone(intent.backend.load())

    def test_preview_has_no_fixture_or_position_requests(self):
        result, backend, intent = run_case(apply=False)
        self.assertEqual(result['result'], 'READ_ONLY_PREVIEW')
        self.assertFalse(backend.imported or backend.sent or intent.backend.load())

    def test_changed_source_after_write_blocks_cleanup(self):
        result, backend, _intent = run_case(changed_source=True)
        self.assertEqual(result['result'], 'UNVERIFIED')
        self.assertEqual(backend.sent, ['enter', 'same'])
        self.assertTrue(backend.imported and not backend.cleanup)


if __name__ == '__main__': unittest.main()
