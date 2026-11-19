"""Imported palette isolation, complete coverage and durable no-replay."""
from copy import deepcopy
import hashlib
import threading
import unittest
from unittest.mock import patch

from annotation_experiment_model import digest
from cb_fixture_color_trial import Intent, STEPS, execute, prepare
from secure_weread_session import StoreError
from test_cb_fixture_highlight_trial import fixture
from test_secure_native_session import Backend
from verify_cb_fixture_color_trial import ScopedNative
from verify_eink_login import NativeProbe


class Fake:
    def __init__(self, baseline, fail=None):
        self.value = deepcopy(baseline); self.sent = []; self.fail = fail; self.valid = True
    def owned(self): return self.valid
    def read(self): return deepcopy(self.value)
    def send(self, index, body, _receipt):
        self.sent.append(index); operation, _ = STEPS[index]
        if operation == 'create':
            row = {k:v for k,v in body.items() if k not in ('bookId', 'bookVersion')}
            row['bookmarkId'] = 'fresh-' + str(index); self.value['marks']['updated'][row['bookmarkId']] = row
        elif operation == 'color': self.value['marks']['updated'][body['bookmarkId']].update(style=body['style'], colorStyle=body['colorStyle'])
        else: del self.value['marks']['updated'][body['bookmarkIds'][0]]
        if self.fail == index: raise RuntimeError('unknown dispatch outcome')


def case(fail=None):
    sample, baseline, _, _ = fixture(); plan, body = prepare('900000', sample['book_id'], 'a'*32, sample, 1, baseline)
    return plan, body, baseline, Intent(Backend()), Fake(baseline, fail)


class PaletteTests(unittest.TestCase):
    def test_full_coordinator_cleans_only_after_verified_palette(self):
        from test_verify_cb_fixture_highlight_trial import FakeUpload
        from verify_cb_fixture_color_trial import run
        sample, baseline, _, _ = fixture(); sample['baseline'] = {'chapter':'0','offset':0,'percent':0}
        grant = {'vid':'900000','accessToken':'synthetic'}; saved = {'vid':'900000','cookies':{'wr_vid':'900000'}}
        class NativeStore:
            def load(self, _owner): return grant
        class Source:
            def __init__(self): self.samples=[]; self.last_checks=dict(catalog_unchanged=True, versions_unchanged=True, position_unchanged=True)
            def set_cookie(self, *_args): pass
            def verify_account(self): pass
            def close(self): pass
            def inspect(self, book): assert book == sample['book_id']; return deepcopy(sample)
        for fault in (None, 5):
            with self.subTest(fault=fault):
                upload = FakeUpload(sample['book_id'], saved['vid'], object()); intent = Intent(Backend())
                class Native(Fake):
                    def __init__(self, book, credentials, authority, _intent):
                        assert book == sample['book_id'] and credentials == grant
                        super().__init__(baseline, fault); self.authority=authority; self.posts=0
                    def version(self, _grant): return 1
                    def observe(self, _grant): assert self.authority(); return self.read()
                    def send(self, index, body, receipt, _grant): self.posts+=1; return super().send(index,body,receipt)
                def uploader(_probe, _journal, _grant, _check, source, *, apply, cleanup_gate):
                    assert apply; upload.imported=True; assert source(sample['book_id'])
                    upload.cleaned=cleanup_gate(upload,upload.receipt,upload.state['plan'],sample['book_id'])
                    if upload.cleaned: upload.imported=False
                    return {'result':'EPUB_IMPORT_AND_SOURCE_VERIFIED' if upload.cleaned else 'UNVERIFIED',
                            'phase':'restored' if upload.cleaned else 'imported'}
                with patch('verify_cb_fixture_highlight_trial.save_refreshed_web_session',return_value=False):
                    report=run(deepcopy(saved),None,NativeStore(),grant,upload,intent,apply=True,uploader=uploader,
                               upload_factory=lambda *_:None,native_factory=Native,source_factory=Source)
                if fault is None:
                    self.assertEqual(report['result'],'CB_FIXTURE_PALETTE_VERIFIED'); self.assertTrue(upload.cleaned)
                    self.assertEqual(report['annotation_posts'],18); self.assertEqual(intent.read(),(None,None))
                else:
                    self.assertEqual(report['result'],'UNVERIFIED'); self.assertFalse(upload.cleaned)
                    self.assertEqual((report['intent_step'],report['intent_phase']),(fault,'claimed'))

    def test_full_palette_roundtrip(self):
        plan, body, baseline, intent, fake = case()
        result = execute(plan, body, baseline, intent, fake.owned, fake.read, fake.send)
        self.assertEqual(result['writes'], 18); self.assertEqual(fake.sent, list(range(18)))
        self.assertEqual({c for op,c in STEPS if op == 'create'}, set(range(6)))
        self.assertEqual({c for op,c in STEPS if op == 'color'}, set(range(6)))
        self.assertEqual(fake.value, baseline); self.assertEqual(intent.read(), (None, None))

    def test_uncertain_step_never_replays(self):
        for index in range(len(STEPS)):
            with self.subTest(index=index):
                plan, body, baseline, intent, fake = case(index)
                with self.assertRaises(RuntimeError): execute(plan, body, baseline, intent, fake.owned, fake.read, fake.send)
                state, _ = intent.read(); self.assertEqual((state['step'], state['phase']), (index, 'claimed'))
                sent = list(fake.sent)
                with self.assertRaises((ValueError, StoreError)): execute(plan, body, baseline, intent, fake.owned, fake.read, fake.send)
                self.assertEqual(fake.sent, sent)

    def test_unrelated_change_stops_and_keeps_claim(self):
        plan, body, baseline, intent, fake = case(); send = fake.send
        def altered(index, value, receipt):
            send(index, value, receipt); fake.value['thoughts']['other'] = {}
        with self.assertRaises(ValueError): execute(plan, body, baseline, intent, fake.owned, fake.read, altered)
        self.assertEqual(fake.sent, [0]); self.assertEqual(intent.read()[0]['phase'], 'claimed')

    def test_wrong_or_repeated_transport_is_rejected(self):
        plan, body, _baseline, intent, fake = case(); grant = {'vid':'900000', 'accessToken':'synthetic'}
        native = ScopedNative(body['bookId'], grant, fake.owned, intent); native.body = body
        receipt = intent.claim(intent.reserve(plan), digest(body))
        with patch.object(NativeProbe, 'request', return_value={'succ':1}) as request:
            with self.assertRaises(ValueError): native.send(0, dict(body, bookId='CB_Other'), receipt, grant)
            native.send(0, body, receipt, grant)
            with self.assertRaises(ValueError): native.send(0, body, receipt, grant)
            self.assertEqual(request.call_count, 1)

    def test_complete_palette_through_real_scoped_loopback_transport(self):
        from mock_weread import CB_READING_ID, CHAPTERS
        from selection_trial_mock import Opener, credentials
        from test_cb_fixture_highlight_native_runtime import Server
        from urllib.parse import urlencode, urlsplit
        from urllib.request import Request
        class PaletteOpener(Opener):
            def open(self, request, timeout):
                if (request.get_header('Vid') != '900000' or request.get_header('Accesstoken') != 'mock-native-access'
                        or urlsplit(request.full_url).hostname != 'i.weread.qq.com'
                        or request.get_method() not in ('GET', 'POST')): raise ValueError('synthetic scope')
                if request.data is not None and urlsplit(request.full_url).path not in (
                        '/book/addBookmark', '/book/updateBookmark', '/book/removeBookmark'): raise ValueError('synthetic scope')
                url = 'http://127.0.0.1:' + str(self.server.server_port) + '/__proxy?' + urlencode(dict(url=request.full_url))
                return self.opener.open(Request(url, data=request.data, headers=dict(request.header_items()),
                                                method=request.get_method()), timeout=timeout)
        server = Server('normal'); server.max_highlight_posts = len(STEPS)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            grant = credentials(); intent = Intent(Backend())
            native = ScopedNative(CB_READING_ID, grant, lambda:True, intent, opener=PaletteOpener(server))
            baseline = native.observe(grant); version = native.version(grant)
            raw = server.chapter_source(2)
            sample = dict(book_id=CB_READING_ID, chapter_uid='2', chapters=CHAPTERS, source_format='web_xhtml',
                          source=raw, source_raw_sha256=hashlib.sha256(raw.encode()).hexdigest())
            plan, body = prepare('900000', CB_READING_ID, 'a'*32, sample, version, baseline)
            native.body = body
            result = execute(plan, body, baseline, intent, lambda:True, lambda:native.observe(grant),
                             lambda index,value,receipt:native.send(index,value,receipt,grant))
            self.assertEqual(result['writes'], len(STEPS)); self.assertEqual(server.highlight_posts, len(STEPS))
            self.assertEqual(native.observe(grant), baseline); self.assertGreater(native.gets, 80)
            self.assertLessEqual(native.gets, 200); self.assertEqual(intent.read(), (None, None))
        finally:
            server.shutdown(); thread.join(); server.server_close()


if __name__ == '__main__': unittest.main()
