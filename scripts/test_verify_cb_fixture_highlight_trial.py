"""Synthetic verification of the owned-fixture integration and network guard."""
import contextlib
from copy import deepcopy
import io
import json
import unittest
from unittest.mock import patch

from cb_fixture_highlight_trial import Intent
from test_cb_fixture_highlight_trial import Fake, fixture
from test_secure_native_session import Backend
from verify_cb_fixture_highlight_trial import ScopedNative, main, run
from verify_eink_login import BASE, NativeProbe


class FakeUpload:
    def __init__(self, book, owner, receipt):
        self.state = dict(phase='imported', target=book, attempt='a' * 32, plan={'owner': owner})
        self.receipt = receipt; self.imported = False; self.cleaned = False
    def read(self): return (self.state, self.receipt) if self.imported else (None, None)


class TrialIntegrationTests(unittest.TestCase):
    def test_offline_entry_point_does_not_load_login(self):
        with patch('verify_cb_fixture_highlight_trial.SessionStore') as saved, contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(main([]), 0)
        saved.assert_not_called(); self.assertEqual(json.loads(output.getvalue())['result'], 'OFFLINE_ONLY')

    def case(self, failure=None, apply=True):
        sample, baseline, _plan, _body = fixture(); sample['baseline'] = {'chapter': '0', 'offset': 0, 'percent': 0}
        grant = {'vid': '900000', 'accessToken': 'synthetic'}; saved = {'vid': '900000', 'cookies': {'wr_vid': '900000'}}
        upload = FakeUpload(sample['book_id'], saved['vid'], object()); intent = Intent(Backend()); natives = []
        class NativeStore:
            def load(self, owner): assert owner == '900000'; return grant
        class Source:
            def __init__(self):
                self.samples = []; self.last_checks = dict(catalog_unchanged=True, versions_unchanged=True, position_unchanged=True)
            def set_cookie(self, *_): pass
            def verify_account(self): pass
            def inspect(self, book): assert book == sample['book_id']; return deepcopy(sample)
            def close(self): pass
        class Native(Fake):
            def __init__(self, book, credentials, authority, _intent):
                assert book == sample['book_id'] and credentials == grant
                super().__init__(baseline, {}, failure); self.authority = authority; self.posts = 0; natives.append(self)
            def version(self, _grant): return 1
            def observe(self, _grant): assert self.authority(); return self.read()
            def send(self, phase, body, receipt, _grant):
                assert self.authority(); self.posts += 1
                if phase == 'create_pending': self.body = deepcopy(body)
                return super().send(phase, body, receipt)
        def uploader(_probe, _journal, _grant, _check, source, *, apply, cleanup_gate):
            if not apply: return {'result': 'READ_ONLY_PREVIEW', 'phase': 'preview'}
            upload.imported = True; assert source(sample['book_id'])
            upload.cleaned = cleanup_gate(upload, upload.receipt, upload.state['plan'], sample['book_id'])
            if upload.cleaned: upload.imported = False
            return dict(result='EPUB_IMPORT_AND_SOURCE_VERIFIED' if upload.cleaned else 'UNVERIFIED',
                        phase='restored' if upload.cleaned else 'imported')
        with patch('verify_cb_fixture_highlight_trial.save_refreshed_web_session', return_value=False):
            result = run(saved, None, NativeStore(), grant, upload, intent, apply=apply, uploader=uploader,
                         upload_factory=lambda *_: None, native_factory=Native, source_factory=Source)
        return result, upload, intent, natives

    def test_success_only_cleans_owned_fixture_after_two_readbacks(self):
        result, upload, intent, natives = self.case()
        self.assertEqual(result['result'], 'CB_FIXTURE_HIGHLIGHT_VERIFIED')
        self.assertEqual(result['annotation_posts'], 2); self.assertTrue(upload.cleaned and not upload.imported)
        self.assertEqual(intent.read(), (None, None)); self.assertEqual(natives[0].sent, ['create_pending', 'delete_pending'])
        self.assertNotIn('CB_Synthetic42', json.dumps(result)); self.assertNotIn('synthetic', json.dumps(result))

    def test_unconfirmed_write_retains_fixture_and_durable_intent(self):
        for phase in ('create_pending', 'delete_pending'):
            result, upload, intent, natives = self.case(phase)
            self.assertEqual(result['result'], 'UNVERIFIED'); self.assertTrue(upload.imported and not upload.cleaned)
            self.assertEqual(intent.read()[0]['phase'], phase)
            self.assertEqual(len(natives[0].sent), 1 if phase == 'create_pending' else 2)

    def test_readonly_preview_does_not_create_fixture_or_intent(self):
        result, upload, intent, natives = self.case(apply=False)
        self.assertEqual(result['result'], 'READ_ONLY_PREVIEW'); self.assertFalse(upload.imported)
        self.assertEqual(intent.read(), (None, None)); self.assertFalse(natives)

    def test_transport_refuses_other_books_and_unclaimed_writes(self):
        sample, baseline, plan, body = fixture(); grant = {'vid': '900000', 'accessToken': 'synthetic'}
        intent = Intent(Backend()); native = ScopedNative(sample['book_id'], grant, lambda: True, intent); native.body = body
        with patch.object(NativeProbe, 'request', return_value={'succ': 1}) as request:
            with self.assertRaises(ValueError): native.request('shelf', BASE + '/shelf/delete', credentials=grant)
            with self.assertRaises(ValueError): native.request('create_pending', BASE + '/book/addBookmark', body, grant)
            receipt = intent.reserve(plan)
            with self.assertRaises(ValueError): native.send('create_pending', dict(body, bookId='CB_Other'), receipt, grant)
            native.send('create_pending', body, receipt, grant)
            self.assertEqual(request.call_count, 1); self.assertEqual(native.posts, 1)
            with self.assertRaises(ValueError): native.send('create_pending', body, receipt, grant)
            with self.assertRaises(ValueError): native.send('delete_pending', {'bookmarkIds': ['existing']}, receipt, grant)
            self.assertEqual(request.call_count, 1)


if __name__ == '__main__':unittest.main()
