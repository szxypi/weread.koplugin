"""Offline boundaries for private real-book acceptance. No owner credentials."""
from contextlib import redirect_stdout, redirect_stderr
import io
import json
import subprocess
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, patch

import verify_owner_reading as probe

OWNER = '900000'
COOKIES = dict(wr_vid=OWNER, wr_skey='synthetic-only-key')


def stage(mode='live'):
    return dict(result='PASS', phase='complete', mode=mode, requests=[1, 4, 3, 2, 4, 6, 0] if mode=='live' else [0]*7,
                shelf_books=139, pages=12, profile_files_audited=40, failed_line=0,
                screenshots=0, last_http_status=200 if mode=='live' else 0, denied_kind=0,denied_route=0,denied_flags=0,
                **dict.fromkeys(probe.FLAGS, True))


def envelope():
    return dict(report=dict(result='PASS', tmpfs_profile=True, profile_removed=True,
                            stages=[stage(), stage('reopen')], runner_error='none'), cookies=COOKIES.copy())


def frame(value):
    return probe.FRAME + json.dumps(value).encode() + b'\n'


class OwnerReadingTests(unittest.TestCase):
    def test_default_never_accesses_owner_or_starts_child(self):
        with patch.object(probe, 'SessionStore') as store, patch.object(probe, 'ReadingPreflight') as web, \
                patch.object(probe.subprocess, 'run') as child, redirect_stdout(io.StringIO()) as output:
            self.assertEqual(probe.main([]), 0)
        store.assert_not_called(); web.assert_not_called(); child.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())['result'], 'OFFLINE_ONLY')

    def test_opt_in_requires_both_session_and_command(self):
        for args in (['--saved-session'], ['--lua-command', 'synthetic']):
            with self.subTest(args=args), redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                probe.main(args)

    def test_private_fields_cannot_enter_public_reports(self):
        for key in ('title', 'book_id', 'source_text', 'cookies', 'raw'):
            value=stage(); value[key]='private'
            with self.assertRaises(ValueError): probe.validate_stage(value, 'live')
            value=envelope(); value['report'][key]='private'
            with self.assertRaises(ValueError): probe.decode_envelope(frame(value), OWNER)

    def test_success_requires_each_proof_and_no_forbidden_request(self):
        for key in probe.FLAGS:
            value=stage(); value[key]=False
            with self.subTest(flag=key), self.assertRaises(ValueError): probe.validate_stage(value, 'live')
        for key, bad in (('shelf_books', 0), ('pages', 1), ('screenshots', 1), ('failed_line', 1),
                         ('profile_files_audited', 0), ('denied_kind', 1), ('phase', 'native'), ('pages', True)):
            value=stage(); value[key]=bad
            with self.subTest(key=key), self.assertRaises(ValueError): probe.validate_stage(value, 'live')
        for index in (0, 2, 3, 4):
            value=stage(); value['requests'][index]=0
            with self.assertRaises(ValueError): probe.validate_stage(value, 'live')
        value=stage(); value['requests'][-1]=1
        with self.assertRaises(ValueError): probe.validate_stage(value, 'live')

    def test_offline_reopen_forbids_every_network_category(self):
        for index in range(7):
            value=stage('reopen'); value['requests'][index]=1
            with self.assertRaises(ValueError): probe.validate_stage(value, 'reopen')

    def test_fresh_process_and_cleanup_are_mandatory(self):
        for key in ('tmpfs_profile', 'profile_removed'):
            value=envelope(); value['report'][key]=False
            with self.assertRaises(ValueError): probe.decode_envelope(frame(value), OWNER)
        for key in ('shelf_books', 'pages'):
            value=envelope(); value['report']['stages'][1][key]+=1
            with self.assertRaises(ValueError): probe.decode_envelope(frame(value), OWNER)
        value=envelope(); value['report']['stages'].pop()
        with self.assertRaises(ValueError): probe.decode_envelope(frame(value), OWNER)

    def test_cookie_envelope_is_strict_and_owner_bound(self):
        for change in (dict(wr_vid='900001'), dict(extra='private'), dict(wr_skey='bad\nvalue'), dict(wr_skey=''),
                       dict(wr_skey='synthetic-\U0001f600-value')):
            value=envelope(); value['cookies'].update(change)
            with self.assertRaises(ValueError): probe.decode_envelope(frame(value), OWNER)
        self.assertEqual(probe.decode_envelope(frame(envelope()), OWNER)['cookies'], COOKIES)

    def test_frame_limits_duplicates_and_private_trailers(self):
        raw=frame(envelope())
        for invalid in (raw+raw, raw+b'private', b'x'*(2*1024*1024)+raw, b'private'):
            with self.assertRaises(ValueError): probe.decode_envelope(invalid, OWNER)

    def test_source_sample_ignores_head_and_script(self):
        parser=probe.SourceText()
        parser.feed('<head><title>'+'A'*40+'</title></head><script>'+'B'*40+'</script><p>'+'正文示例'*12+'</p>')
        self.assertEqual(parser.samples, [('正文示例'*12)[:32]])

    def run_online(self, child_result=None, after=None, rotated=None):
        web=MagicMock()
        web.report=dict(stages=[])
        web.prepare.return_value=dict(book_id='900001', chapter_uid='2', source_text='private source',
                                      shelf_ids=['900001'], shelf_books=139)
        web.book_id='900001'; web.baseline=dict(chapter='2', offset=10, percent=20)
        web.request.return_value=after or dict(bookId='900001', chapterUid=2, chapterOffset=10, progress=20)
        result=child_result or SimpleNamespace(returncode=0, stdout=frame(envelope()), stderr=b'private child diagnostics')
        snapshots=iter((dict(vid=OWNER, cookies=COOKIES.copy()), dict(vid=OWNER, cookies=rotated or COOKIES.copy())))
        with patch.object(probe, 'SessionStore') as store, patch.object(probe, 'ReadingPreflight', return_value=web), \
                patch.object(probe, 'save_refreshed_web_session', return_value=False), \
                patch.object(probe.subprocess, 'run', **({'side_effect':result} if isinstance(result, Exception)
                                                      else {'return_value':result})) as child, redirect_stdout(io.StringIO()) as output:
            store.return_value.load.side_effect=lambda: next(snapshots)
            code=probe.main(['--saved-session', '--lua-command', 'synthetic'])
        public=output.getvalue()
        self.assertNotIn('synthetic-only-key', public)
        self.assertNotIn('private source', public)
        self.assertNotIn('private child diagnostics', public)
        self.assertEqual(web.close.call_count, 1)
        return code, json.loads(public), child

    def test_success_verifies_owner_again_and_unchanged_cloud(self):
        code, public, child=self.run_online()
        self.assertEqual(code, 0)
        self.assertTrue(public['cloud_position_unchanged'])
        self.assertEqual(public['result'], 'OWNER_NATIVE_READING_VERIFIED')
        self.assertEqual(child.call_args.kwargs['timeout'], 320)

    def test_child_receives_verified_keychain_readback_after_rotation(self):
        rotated=dict(COOKIES, wr_skey='synthetic-rotated-value')
        code, _public, child=self.run_online(rotated=rotated)
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(child.call_args.kwargs['input'])['cookies'], rotated)

    def test_failed_child_or_changed_cloud_cannot_pass(self):
        code, public, _child=self.run_online(SimpleNamespace(returncode=1, stdout=frame(envelope()), stderr=b''))
        self.assertEqual(code, 1); self.assertEqual(public['result'], 'UNVERIFIED')
        code, public, _child=self.run_online(after=dict(bookId='900001', chapterUid=2, chapterOffset=11, progress=20))
        self.assertEqual(code, 1); self.assertFalse(public['cloud_position_unchanged'])

    def test_timeout_and_invalid_private_output_are_sanitized(self):
        code, public, _child=self.run_online(SimpleNamespace(returncode=1, stdout=b'private secret', stderr=b'private'))
        self.assertEqual(code, 1); self.assertEqual(public['reason'], 'owner_reading_unverified')
        code, public, _child=self.run_online(subprocess.TimeoutExpired('private command', 320, output=b'private key'))
        self.assertEqual(code, 1); self.assertEqual(public['reason'], 'owner_reading_unverified')


if __name__ == '__main__':
    unittest.main()
