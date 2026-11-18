import copy
from contextlib import redirect_stdout
import io
import json
import unittest
from unittest.mock import patch

from cb_initial_fixture_intent import Intent
from test_cb_fixture_position import fixture
from test_cb_fixture_position_transport import MemoryBackend
from test_cloud_group_contract import shelf
import verify_cb_initial_fixture_ui_trial as task


class Backend:
    def __init__(self, txt=False):
        self.book, self.sample = fixture(); self.sample['source_raw_sha256'] = 'f' * 64
        if txt:
            from verify_cb_txt_fixture import MARKER
            self.sample.update(source_format='web_txt', source=MARKER + '\nA second synthetic line.')
        self.owner = '900000'; self.imported = False; self.calls = []
        self.current = dict(bookId=self.book, chapterUid=0, chapterIdx=0, chapterOffset=0,
                            progress=0, summary='', readingTime=0, recordReadingTime=0, ttsTime=0)
        self.receipt = object(); self.cleanup = False
        self.state = dict(phase='imported', target=self.book, attempt='a' * 32, plan=dict(owner=self.owner))
    def read(self): return (self.state, self.receipt) if self.imported else (None, None)


def run_case(*, fail=None, apply=True, txt=False, fixture_authorized=None):
    backend = Backend(txt); grant = {'vid': backend.owner}
    saved = dict(vid=backend.owner, cookies={'wr_vid': backend.owner, 'wr_skey': 'synthetic'})
    intent = Intent(backend=MemoryBackend()); command = ['synthetic-runner']
    class NativeStore:
        def load(self, _owner): return grant
    class BaseWeb:
        def __init__(self): self.authenticated = False; self.samples = []; self.book_id = None
        def set_cookie(self, *_): pass
        def verify_account(self): self.authenticated = True
        def close(self): pass
    class Web(BaseWeb):
        def request(self, stage, _url):
            if stage == 'progress_after': return {'book': copy.deepcopy(backend.current)}
            assert stage == 'shelf'
            value = shelf()
            if backend.imported: value['books'].append(dict(bookId=backend.book, title='test', finishReading=0, secret=0))
            return value
    class Source(BaseWeb):
        def __init__(self):
            super().__init__(); self.allowed = set(); self.catalog_versions = {'record.version': 1}
            self.last_checks = dict(catalog_unchanged=True, versions_unchanged=True, position_unchanged=True)
        def inspect(self, target):
            assert target == backend.book and target in self.allowed
            return copy.deepcopy(backend.sample)
    class Native:
        def __init__(self, _grant, target): assert target == backend.book
        def request(self, *_args, **_kwargs): return {'book': copy.deepcopy(backend.current)}
    def ui_runner(_command, payload):
        backend.calls.append(payload['armed'])
        if fail == 'dry' and not payload['armed']: raise ValueError('dry failed')
        if payload['armed']:
            backend.current.update(chapterUid=payload['chapter'], chapterIdx=payload['chapter_idx'],
                                   chapterOffset=payload['offset'], progress=17, summary=payload['expected_summary'])
            if fail == 'armed': raise ValueError('unknown result')
        return True
    def uploader(_probe, _journal, _grant, _check, source, *, apply, cleanup_gate):
        if not apply: return dict(result='READ_ONLY_PREVIEW', phase='preview')
        backend.imported = True; assert source(backend.book)
        try: backend.cleanup = cleanup_gate(backend, backend.receipt, backend.state['plan'], backend.book)
        except Exception: backend.cleanup = False
        if backend.cleanup: backend.imported = False
        return dict(result=('TXT_IMPORT_AND_SOURCE_VERIFIED' if txt else 'EPUB_IMPORT_AND_SOURCE_VERIFIED') if backend.cleanup else 'UNVERIFIED',
                    phase='restored' if backend.cleanup else 'imported', cos_put_attempts=1,
                    notify_posts=1, cleanup_posts=int(backend.cleanup))
    attests = []
    def attest():
        attests.append(True)
        return ['changed'] if fail == 'attestation' and len(attests) > 1 else command
    with patch.object(task, 'WebSourceProbe', Web), patch.object(task, 'SourceRead', Source), \
         patch.object(task, 'NativeRead', Native), patch.object(task, 'save_refreshed_web_session', return_value=False):
        options = {}
        if txt:
            from cb_txt_initial_fixture_plan import plan
            from verify_cb_txt_fixture import MARKER
            from verify_cb_txt_initial_fixture_ui_trial import summary
            options = dict(source_format='web_txt', source_marker=MARKER, position_planner=plan, summary_planner=summary,
                           upload_success='TXT_IMPORT_AND_SOURCE_VERIFIED', fixture_authorized=fixture_authorized)
        result = task.run(saved, None, NativeStore(), grant, backend, intent, command, apply=apply,
                          upload_factory=lambda *_: None, uploader=uploader, ui_runner=ui_runner, attest=attest, **options)
    return result, backend, intent


class TrialTest(unittest.TestCase):
    def test_offline_default_does_not_open_session_or_runtime(self):
        with patch.object(task, 'SessionStore') as session, patch.object(task, 'ui_command') as command, redirect_stdout(io.StringIO()) as out:
            self.assertEqual(task.main([]), 0)
        session.assert_not_called(); command.assert_not_called(); self.assertEqual(json.loads(out.getvalue())['result'], 'OFFLINE_ONLY')

    def test_full_owned_fixture_and_private_result(self):
        result, backend, _intent = run_case()
        self.assertEqual(result['result'], 'CB_FIRST_NATIVE_UI_VERIFIED')
        self.assertEqual(backend.calls, [False, True]); self.assertTrue(backend.cleanup and not backend.imported)
        self.assertEqual(result['position_writes_known'], 1); self.assertEqual(result['account_data_writes_known'], 4)
        self.assertNotIn(backend.book, json.dumps(result)); self.assertNotIn('synthetic', json.dumps(result))

    def test_failure_retains_fixture_and_never_rearms(self):
        for failure, calls in (('dry', [False]), ('armed', [False, True]), ('attestation', [False])):
            result, backend, intent = run_case(fail=failure)
            self.assertEqual(result['result'], 'UNVERIFIED'); self.assertEqual(backend.calls, calls)
            self.assertTrue(backend.imported and not backend.cleanup); self.assertIsNotNone(intent.backend.load())
            self.assertEqual(result['position_writes_uncertain'], failure == 'armed')

    def test_preview_has_no_fixture_or_ui_call(self):
        result, backend, intent = run_case(apply=False)
        self.assertEqual(result['result'], 'READ_ONLY_PREVIEW')
        self.assertFalse(backend.imported or backend.calls or intent.backend.load())

    def test_txt_ui_requires_fresh_fixture_receipt_throughout(self):
        result, backend, _intent = run_case(txt=True, fixture_authorized=lambda *_: True)
        self.assertEqual(result['result'], 'CB_FIRST_NATIVE_UI_VERIFIED')
        self.assertEqual(backend.calls, [False, True]); self.assertTrue(backend.cleanup)
        result, backend, intent = run_case(txt=True, fixture_authorized=lambda upload, *_: not upload.calls)
        self.assertEqual(result['result'], 'UNVERIFIED'); self.assertEqual(backend.calls, [False])
        self.assertTrue(backend.imported and not backend.cleanup); self.assertIsNotNone(intent.backend.load())


if __name__ == '__main__': unittest.main()
