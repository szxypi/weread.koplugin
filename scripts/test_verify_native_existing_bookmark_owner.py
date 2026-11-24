from contextlib import redirect_stdout
import hashlib
import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from bookmark_point import first_position, project
from verify_native_existing_bookmark_owner import eligible_point, main, select


class ExistingBookmarkOwnerTests(unittest.TestCase):
    def setUp(self):
        self.text = '<html><body><p>Unique existing bookmark content with sufficient context.</p></body></html>'
        self.raw = self.text.encode()
        self.co = first_position(self.text)
        point = project(self.text, self.co)
        self.row = dict(bookmarkId='synthetic-point', chapterUid=37, type=0,
                        range=point['range'], markText=point['markText'])

    def test_point_requires_source_scope_and_exact_preview(self):
        point = eligible_point(self.raw, '42', '37', self.row)
        self.assertEqual(point['chapter_offset'], self.co)
        self.assertEqual(point['raw_sha256'], hashlib.sha256(self.raw).hexdigest())
        for row in (dict(self.row, range='0'), dict(self.row, chapterUid=38),
                    dict(self.row, markText='unrelated preview')):
            with self.assertRaises(ValueError):eligible_point(self.raw, '42', '37', row)
        with self.assertRaises((ValueError, UnicodeError)):
            eligible_point(b'\xff', '42', '37', self.row)

    def test_select_skips_bad_points_and_requires_available_other_chapter(self):
        row = self.row
        class Native:
            def request(self, stage, url, **kwargs):
                self_test.assertNotIn('body', kwargs)
                if stage == 'shelf':return {'books': [{'bookId': '42'}]}
                if stage == 'notebooks':return {'books': [{'book': {'bookId': '42'}, 'bookmarkCount': 2}]}
                if stage == 'marks':return {}
                raise AssertionError(stage)
        class Chapter:
            allowed = None
            def request(self, *_args, **_kwargs):return {}
            def download(self, *_args):return b'archive', 'envelope'
        self_test = self
        model = {'format': 'epub', 'version': 1, 'chapters': [
            {'uid': 37, 'free_or_owned': True, 'wordCount': 20},
            {'uid': 38, 'free_or_owned': True, 'wordCount': 20}]}
        marks = {'updated': [dict(row, range='0'), row]}
        with patch('verify_native_existing_bookmark_owner.marks_project', return_value=marks), \
             patch('verify_native_existing_bookmark_owner.ChapterProbe', Chapter), \
             patch('verify_native_existing_bookmark_owner.catalog', return_value=model), \
             patch('verify_native_existing_bookmark_owner.password', return_value='key'), \
             patch('verify_native_existing_bookmark_owner.read', return_value={'html': True, 'source': self.raw}):
            source, selected, point = select(Native(), {'vid': '12345678'})
            self.assertIs(selected, row)
            self.assertEqual(source['source_sha256'], hashlib.sha256(self.raw).hexdigest())
            self.assertEqual(point['chapter_offset'], self.co)
            model['chapters'][1]['free_or_owned'] = False
            with self.assertRaisesRegex(ValueError, 'no_eligible_sample'):
                select(Native(), {'vid': '12345678'})

    def test_owner_orchestration_reports_only_safe_metadata_and_checks_final_state(self):
        original = {'marks': {'updated': {self.row['bookmarkId']: self.row}}, 'shelf': {'42': {}},
                    'thoughts': {}, 'position': {'chapter': '37'}}
        source = {'book_id': '42', 'uid': '37', 'book_version': 1, 'source': self.raw,
                  'source_sha256': hashlib.sha256(self.raw).hexdigest()}
        point = eligible_point(self.raw, '42', '37', self.row)
        class Session:
            def load(self):return {'vid': '12345678', 'cookies': {'secret': 'PRIVATE_COOKIE'}}
        class NativeSession:
            def load(self, _owner):return {'vid': '12345678', 'accessToken': 'PRIVATE_TOKEN'}
        class Notes:
            changed = False
            def observe(self, _grant, stage):
                if self.changed and stage == 'existing_bookmark_final':return dict(original, shelf={})
                return original
        class Web:
            def set_cookie(self, *_args):pass
            def verify_account(self):pass
            def request(self, *_args, **_kwargs):return 'synthetic'
            def close(self):pass
        def run(adapter, grant, candidate, origin, target, command):
            self.assertEqual(adapter.read(grant)[1], original)
            self.assertEqual((candidate, origin, target['id'], command), (source, {}, self.row['bookmarkId'], ['runner']))
            return dict(screens=2, indicator_tap_verified=True, offline_reopen=True)
        replacements = dict(SessionStore=Session, NativeSessionStore=NativeSession, NativeProbe=lambda: None,
                            select=lambda *_args: (source, self.row, point), AnnotationProbe=Notes,
                            prepare_origin=lambda *_args: {}, WebSourceProbe=Web,
                            reading_position=lambda *_args: {'chapter': '37'},
                            read_reader_state=lambda *_args: SimpleNamespace(psvts='synthetic'),
                            make_content_params=lambda *_args, **_kwargs: {},
                            decode_content_shards=lambda *_args: self.text,
                            save_refreshed_web_session=lambda *_args: None, verify=run)
        with patch.multiple('verify_native_existing_bookmark_owner', **replacements), \
             patch('verify_native_existing_bookmark_owner.resource.setrlimit'):
            for changed in (False, True):
                Notes.changed = changed;output = io.StringIO()
                with redirect_stdout(output):status = main(['--saved-session', '--lua-command', 'runner'])
                report = json.loads(output.getvalue())
                self.assertNotIn('PRIVATE_', output.getvalue())
                self.assertEqual(report['account_data_writes'], 0)
                self.assertEqual(status, int(changed))
                self.assertEqual(report['result'], 'UNVERIFIED' if changed else 'EXISTING_BOOKMARK_OWNER_VERIFIED')
                if changed:self.assertEqual(report['reason'], 'owner_bookmark/account_changed')


if __name__ == '__main__':
    unittest.main()
